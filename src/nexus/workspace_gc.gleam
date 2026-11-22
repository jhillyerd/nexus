//// Guarded workspace disk garbage collection (docs/plans/workspace-sandbox.md,
//// Phase 1, #126).
////
//// Workspace rows are tombstoned (`deleted_at IS NOT NULL`) inside the same
//// atomic SQL statement that deletes or prunes their owning thread(s). This
//// module performs the filesystem side:
////
//// - `safe_target_path` validates `(root, rel_path)` lexically before any
////   recursive remove — rejecting blank inputs, non-absolute roots, `/` as a
////   root, `..` segments, absolute `rel_path`s, NUL bytes, and anything that
////   does not resolve strictly inside `root`.
//// - `remove_dir` runs `simplifile.delete` (Erlang `file:del_dir_r`, which
////   unlinks symlinks without following them) and treats `Enoent` as `Ok(Nil)`
////   because workspace directories are created lazily and retries must be
////   idempotent.
//// - `cleanup` / `cleanup_async` remove tombstoned directories and hard-delete
////   each `workspace` row only on `Ok(Nil)` — any path-safety refusal or
////   filesystem error is logged and leaves the tombstone in place for the next
////   boot sweep.
//// - `sweep` runs at boot (`persist.boot_sweeps`) to finish any tombstones
////   left behind by `prune_never_used`, crashes, or transient filesystem
////   errors.

import filepath
import gleam/erlang/process
import gleam/list
import gleam/result
import gleam/string
import nexus/env
import nexus/log
import nexus/store
import simplifile

/// Validate `(root, rel_path)` and return the normalized target path
/// strictly beneath `root`.
pub fn safe_target_path(
  root: String,
  rel_path: String,
) -> Result(String, String) {
  let trimmed_root = string.trim(root)
  let trimmed_rel = string.trim(rel_path)
  case trimmed_root == "" || trimmed_rel == "" {
    True -> Error("workspace root and rel_path must be non-empty")
    False ->
      case
        string.contains(root, "\u{0}") || string.contains(rel_path, "\u{0}")
      {
        True -> Error("workspace path must not contain NUL bytes")
        False ->
          case string.starts_with(root, "/") {
            False -> Error("workspace root must be absolute: " <> root)
            True ->
              case has_dotdot(root) {
                True -> Error("workspace root must not contain '..': " <> root)
                False ->
                  case
                    string.starts_with(rel_path, "/")
                    || filepath.is_absolute(rel_path)
                  {
                    True ->
                      Error("workspace rel_path must be relative: " <> rel_path)
                    False ->
                      case has_dotdot(rel_path) {
                        True ->
                          Error(
                            "workspace rel_path must not contain '..': "
                            <> rel_path,
                          )
                        False -> {
                          let norm_root = env.normalize(root)
                          case norm_root == "/" {
                            True -> Error("workspace root cannot be '/'")
                            False -> {
                              let target =
                                env.normalize(filepath.join(norm_root, rel_path))
                              case
                                target != norm_root
                                && string.starts_with(target, norm_root <> "/")
                              {
                                True -> Ok(target)
                                False ->
                                  Error(
                                    "workspace target is not strictly inside root: "
                                    <> target,
                                  )
                              }
                            }
                          }
                        }
                      }
                  }
              }
          }
      }
  }
}

fn has_dotdot(path: String) -> Bool {
  path
  |> string.split("/")
  |> list.any(fn(segment) { segment == ".." })
}

/// Guarded recursive removal of one workspace directory. `Enoent` counts as
/// success (lazy creation / idempotent crash recovery). Re-checks absence
/// after deletion (retrying once if an asynchronously killed worker raced
/// and recreated files) so a tombstone row is never dropped while files
/// remain on disk. Any path-safety violation or filesystem error returns
/// `Error` so the caller keeps the tombstone row.
pub fn remove_dir(root: String, rel_path: String) -> Result(Nil, String) {
  use target <- result.try(safe_target_path(root, rel_path))
  use Nil <- result.try(delete_once(target))
  case simplifile.link_info(target) {
    Error(simplifile.Enoent) -> Ok(Nil)
    Ok(_) -> {
      use Nil <- result.try(delete_once(target))
      case simplifile.link_info(target) {
        Error(simplifile.Enoent) -> Ok(Nil)
        Ok(_) -> Error("workspace still present after retry: " <> target)
        Error(err) ->
          Error(
            "failed to verify workspace removal "
            <> target
            <> ": "
            <> simplifile.describe_error(err),
          )
      }
    }
    Error(err) ->
      Error(
        "failed to verify workspace removal "
        <> target
        <> ": "
        <> simplifile.describe_error(err),
      )
  }
}

fn delete_once(target: String) -> Result(Nil, String) {
  case simplifile.delete(target) {
    Ok(Nil) -> Ok(Nil)
    Error(simplifile.Enoent) -> Ok(Nil)
    Error(err) ->
      Error(
        "failed to remove workspace "
        <> target
        <> ": "
        <> simplifile.describe_error(err),
      )
  }
}

/// Clean up tombstoned workspaces synchronously: remove each directory on
/// disk and hard-delete its `workspace` row only on success. Returns the
/// number of rows hard-deleted.
pub fn cleanup(
  db: store.Store,
  workspaces: List(store.TombstonedWorkspace),
) -> Int {
  list.fold(workspaces, 0, fn(removed, ws) {
    case remove_dir(ws.root, ws.rel_path) {
      Error(reason) -> {
        log.error("workspace_gc", "refused or failed workspace removal", [
          log.str("workspace_id", ws.id),
          log.str("root", ws.root),
          log.str("rel_path", ws.rel_path),
          log.str("error", reason),
        ])
        removed
      }
      Ok(Nil) ->
        case db.delete_workspace(ws.id) {
          Ok(Nil) -> removed + 1
          Error(error) -> {
            log.error("workspace_gc", "failed to delete tombstoned row", [
              log.str("workspace_id", ws.id),
              log.str("error", error),
            ])
            removed
          }
        }
    }
  })
}

/// Spawn an unlinked background cleanup task for a batch of tombstoned
/// workspaces. No-op when `workspaces` is empty.
pub fn cleanup_async(
  db: store.Store,
  workspaces: List(store.TombstonedWorkspace),
) -> Nil {
  case workspaces {
    [] -> Nil
    _ -> {
      let _ =
        process.spawn_unlinked(fn() {
          let _ = cleanup(db, workspaces)
          Nil
        })
      Nil
    }
  }
}

/// Boot GC sweep (`sweep_deleted_workspaces`): remove every tombstoned
/// workspace directory and hard-delete its row on success.
pub fn sweep(db: store.Store) -> Nil {
  case db.list_deleted_workspaces() {
    Error(error) ->
      log.error("workspace_gc", "boot sweep failed", [
        log.str("sweep", "deleted_workspaces"),
        log.str("error", error),
      ])
    Ok([]) ->
      log.info("workspace_gc", "boot sweep found no tombstoned workspaces", [])
    Ok(tombstoned) -> {
      let removed = cleanup(db, tombstoned)
      log.info("workspace_gc", "boot sweep finished", [
        log.int("pending", list.length(tombstoned)),
        log.int("removed", removed),
      ])
    }
  }
}
