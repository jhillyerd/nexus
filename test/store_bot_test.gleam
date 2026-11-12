//// Offline bot-store tests — Phase 1 of docs/plans/bots.md.
////
//// The `bot` table's seam contract against the in-memory mock: CRUD
//// round-trip with the unique-name constraint, the provider RESTRICT,
//// the delete guard's count, and the SET NULL propagation — deleting a\n//// bot must NULL the stored threads' provenance while leaving their\n//// frozen columns (provider/model/prompt) untouched. The pog-backed\n//// implementation is drift-gated in CI by `squirrel check`; these pin\n//// the seam's semantics.

import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import nexus/bot
import nexus/store
import nexus/thread
import store_mock

fn row(id: String, name: String) -> store.StoredBot {
  bot.Bot(
    id: id,
    name: name,
    description: "bot " <> name,
    provider_id: store_mock.fixture_provider_id,
    model: "alias-1",
    system_prompt: None,
    tools: None,
    created_at: 1_700_000_000,
    updated_at: 1_700_000_000,
  )
}

fn summary(id: String, bot_id: option.Option(String)) -> store.StoredSummary {
  store.StoredSummary(
    id: id,
    provider_id: store_mock.fixture_provider_id,
    model: "alias-1",
    meta: thread.ThreadMeta(
      title: "",
      title_source: thread.AutoTitle,
      pinned: False,
      tags: [],
      tags_manual: [],
      tags_source: thread.AutoTags,
      archived: False,
      bot_id: bot_id,
      created_at: 1_700_000_000,
    ),
    last_active_at: 1_700_000_000,
    toolset: [],
    message_count: 1,
  )
}

fn seam() -> store.Store {
  let seam = store_mock.seam(store_mock.start())
  store_mock.ensure_fixture_provider(seam)
  seam
}

pub fn bot_crud_round_trips_test() {
  let seam = seam()
  let assert Ok(Nil) = seam.insert_bot(row("b1", "one"))

  let assert Ok(got) = seam.get_bot("b1")
  should.equal(got.name, "one")
  should.equal(got.system_prompt, None)

  let assert Ok(Nil) =
    seam.update_bot(bot.Bot(..row("b1", "renamed"), system_prompt: Some("p")))

  let assert Ok(updated) = seam.get_bot("b1")
  should.equal(updated.name, "renamed")
  should.equal(updated.system_prompt, Some("p"))

  let assert Ok(all) = seam.list_bots()
  should.equal(all |> list.map(fn(b) { b.id }), ["b1"])

  let assert Ok(Nil) = seam.delete_bot("b1")
  seam.get_bot("b1") |> should.be_error
}

pub fn duplicate_bot_id_and_name_rejected_test() {
  let seam = seam()
  let assert Ok(Nil) = seam.insert_bot(row("b1", "one"))
  // bot_pkey
  seam.insert_bot(row("b1", "other")) |> should.be_error
  // bot_name
  seam.insert_bot(row("b2", "one")) |> should.be_error
}

pub fn bot_provider_fk_restrict_test() {
  let seam = seam()
  // An unknown provider id refuses the insert (the FK is the backstop
  // behind the callers' friendly-400 checks).
  seam.insert_bot(bot.Bot(..row("b1", "one"), provider_id: "p-nope"))
  |> should.be_error
  // ...and a move onto an unknown provider refuses the update.
  let assert Ok(Nil) = seam.insert_bot(row("b1", "one"))
  seam.update_bot(bot.Bot(..row("b1", "one"), provider_id: "p-nope"))
  |> should.be_error
}

pub fn count_and_provider_delete_guard_test() {
  let seam = seam()
  let assert Ok(Nil) = seam.insert_bot(row("b1", "one"))
  let assert Ok(1) =
    seam.count_bots_for_provider(store_mock.fixture_provider_id)
  let assert Ok(0) = seam.count_bots_for_provider("p-other")

  // RESTRICT: the pinned provider refuses to delete while a bot points\n  // at it (the registry's 409 pre-check is the friendly copy).
  seam.delete_provider(store_mock.fixture_provider_id) |> should.be_error

  let assert Ok(Nil) = seam.delete_bot("b1")
  let assert Ok(Nil) = seam.delete_provider(store_mock.fixture_provider_id)
}

pub fn deleting_bot_nulls_thread_provenance_test() {
  let seam = seam()
  let assert Ok(Nil) = seam.insert_bot(row("b1", "one"))

  // A bot-sourced thread row: provenance set, frozen columns explicit.
  let assert Ok(Nil) =
    seam.insert_thread(summary("s1", Some("b1")), "bot prompt")
  let assert Ok(Nil) = seam.insert_thread(summary("s2", None), "default")

  let assert Ok(Nil) = seam.delete_bot("b1")

  // SET NULL: both threads survive with their frozen columns intact;
  // only the provenance pointer disappeared.
  let assert Ok(t1) = seam.get_thread("s1")
  should.equal(t1.summary.meta.bot_id, None)
  should.equal(t1.system_prompt, "bot prompt")
  should.equal(t1.summary.model, "alias-1")
  let assert Ok(t2) = seam.get_thread("s2")
  should.equal(t2.summary.meta.bot_id, None)
}

pub fn insert_thread_requires_known_bot_test() {
  let seam = seam()
  // The insert-time half of the bot FK: provenance must reference a
  // stored row (after insert, only delete can NULL it).
  seam.insert_thread(summary("s1", Some("b-nope")), "p")
  |> should.be_error
}

pub fn updating_bot_never_touches_threads_test() {
  let seam = seam()
  let assert Ok(Nil) = seam.insert_bot(row("b1", "one"))
  let assert Ok(Nil) =
    seam.insert_thread(summary("s1", Some("b1")), "frozen at creation")

  // The bot is a creation-time template: even a full-row edit (rename,\n  // re-aim, new prompt) changes nothing about the existing thread.
  let assert Ok(Nil) =
    seam.update_bot(
      bot.Bot(
        ..row("b1", "renamed"),
        model: "alias-9",
        system_prompt: Some("new prompt"),
      ),
    )

  let assert Ok(t1) = seam.get_thread("s1")
  should.equal(t1.system_prompt, "frozen at creation")
  should.equal(t1.summary.model, "alias-1")
  // The provenance POINTER stays the id; it is never re-read.
  should.equal(t1.summary.meta.bot_id, Some("b1"))
}
