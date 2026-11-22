%% M3 tool-adapter FFI: bounded buffered requests and host resolution for
%% the http_fetch / web_fetch SSRF guard. Body size is enforced here (not
%% in Gleam) so a multi-gigabyte response cannot be materialised before
%% truncation.
-module(nexus_net_ffi).

-export([bounded_request/6, resolve_host/1, to_text_lossy/1,
         inflate_bounded/3]).

%% Hard caps on the collected response-header set (context-window hygiene,
%% not memory: hackney has already materialised the head by the time we see
%% it). Pairs are counted as `name: value` bytes; a set that would cross
%% either cap is cut and flagged so the model knows headers were dropped.
-define(MAX_HEADER_PAIRS, 128).
-define(MAX_HEADERS_BYTES, 8192).

%% Method+body bounded request (Phase 5 curl upgrades,
%% docs/plans/web-fetch.md): cap/deadline posture plus the full
%% response-header set (lowercased, duplicates joined, capped) alongside
%% the existing derived fields. The former bounded_get/4 GET wrapper was
%% removed when net.gleam's fetch became a GET wrapper over
%% bounded_request/6 — it had no remaining callers.
bounded_request(Method, Url, Headers, Body, MaxBytes, TimeoutMs) ->
    %% Hard total deadline. hackney's {connect_timeout, T} bounds only the
    %% TCP stage: hackney 1.25's hackney_ssl:connect/4 then performs the
    %% TLS handshake with ssl:connect(Sock, Opts) — the two-argument form,
    %% no timeout, i.e. infinity — and {recv_timeout, T} only starts after
    %% the request has been sent. A host that completes the TCP connect
    %% but stalls the TLS handshake therefore hangs hackney:request
    %% forever — the bug class fixed upstream in hackney 4.0.1 (PR #781 /
    %% GHSA-gp9c-pm5m-5cxr; nexus pins 1.x), which is when this wrapper
    %% can go. Until then, bound it here: run the fetch in a throwaway
    %% worker and kill it at the deadline — gen_tcp/ssl sockets die with
    %% their owner process, so the kill also closes the connection. The
    %% deadline bounds the WHOLE hop — connect, handshake, response head,
    %% AND body streaming — so 2*T + slack is only the normal-path worst
    %% case; a slow-dribbling body can also hit it and answers as a
    %% deadline error, which is tool DATA for the model, never a turn
    %% error. Clamped at 0 so no caller can make `after` raise badarg
    %% with a negative value (config load rejects those loudly; this is
    %% defense in depth at the FFI boundary).
    Deadline = max(0, 2 * TimeoutMs + 2000),
    Owner = self(),
    Ref = make_ref(),
    Pid = spawn(fun() ->
        Result = try bounded_request_inner(Method, Url, Headers, Body,
                                           MaxBytes, TimeoutMs) of
            Outcome -> Outcome
        catch
            Class:Reason -> {error, format_reason({Class, Reason})}
        end,
        Owner ! {Ref, Result}
    end),
    receive
        {Ref, Result} -> Result
    after Deadline ->
        exit(Pid, kill),
        %% A result that raced the deadline is discarded — the deadline is
        %% the answer. Drain anything already sent so the caller's mailbox
        %% never carries stale {Ref, _} tuples.
        flush_result(Ref),
        {error, <<"timeout (hard deadline)">>}
    end.

flush_result(Ref) ->
    receive
        {Ref, _} -> flush_result(Ref)
    after 0 -> ok
    end.

bounded_request_inner(Method, Url, Headers, Body, MaxBytes, TimeoutMs) ->
    case method_atom(Method) of
        {error, Reason} ->
            {error, Reason};
        {ok, MethodAtom} ->
            do_bounded_request(MethodAtom, Url, Headers, Body, MaxBytes,
                               TimeoutMs)
    end.

do_bounded_request(MethodAtom, Url, Headers, Body, MaxBytes, TimeoutMs) ->
    Opts = [{connect_timeout, TimeoutMs}, {recv_timeout, TimeoutMs}],
    case hackney:request(MethodAtom, Url, Headers, Body, Opts) of
        %% Bodiless responses — HEAD requests, and 204/304 statuses — come
        %% back WITHOUT a client ref (hackney closes the connection
        %% itself): the body is empty by definition and nothing streams.
        {ok, Status, RespHeaders} ->
            {ok, make_fetch_response(Status, RespHeaders, Url, <<>>, false)};
        {ok, Status, RespHeaders, Client} ->
            case read_body(Client, MaxBytes, <<>>, false) of
                {ok, RespBody, Truncated} ->
                    {ok, make_fetch_response(Status, RespHeaders, Url,
                                             RespBody, Truncated)};
                {error, Reason} ->
                    hackney:close(Client),
                    {error, format_reason(Reason)}
            end;
        {error, Reason} ->
            {error, format_reason(Reason)}
    end.

make_fetch_response(Status, RespHeaders, Url, RespBody, Truncated) ->
    ContentType = header(RespHeaders, <<"content-type">>),
    ContentEncoding =
        string:lowercase(headers_joined(RespHeaders, <<"content-encoding">>)),
    Location = header(RespHeaders, <<"location">>),
    {RespHeaderList, HeadersTruncated} = collect_headers(RespHeaders),
    {fetch_response, Status, ContentType, Location, RespBody, Truncated,
     Url, ContentEncoding, RespHeaderList, HeadersTruncated}.

%% Whitelist-map the method string to a hackney atom. The Gleam layer only
%% produces the seven standard verbs (http.Method), but the FFI never
%% trusts its caller: binary_to_atom on model-supplied bytes would mint
%% atoms (atom-table exhaustion) and arbitrary verbs could smuggle
%% request-splitting past the adapter — an unknown string is an error.
method_atom(<<"GET">>) -> {ok, get};
method_atom(<<"HEAD">>) -> {ok, head};
method_atom(<<"POST">>) -> {ok, post};
method_atom(<<"PUT">>) -> {ok, put};
method_atom(<<"PATCH">>) -> {ok, patch};
method_atom(<<"DELETE">>) -> {ok, delete};
method_atom(<<"OPTIONS">>) -> {ok, options};
method_atom(Other) ->
    {error, <<"unsupported method: ", Other/binary>>}.

%% The full response-header set as {LowercaseName, Value} pairs: names
%% lowercased, duplicate names' values joined with ", " per RFC 9110 —
%% which EXCLUDES set-cookie from combination (§5.2: cookie values legally
%% embed commas, e.g. Expires=Wed, 21 Oct 2015 07:28:00 GMT, so joining
%% would corrupt the cookie and it could not be split back) — first-seen
%% order preserved, and the whole set capped at ?MAX_HEADER_PAIRS pairs /
%% ?MAX_HEADERS_BYTES rendered bytes with Truncated=true when the cap cut
%% it (the model sees headers_truncated and knows the tail was dropped).
%% set-cookie pairs stay SEPARATE verbatim entries; the Gleam tool layer
%% chooses their representation.
collect_headers(RespHeaders) ->
    collect_capped(group_headers(RespHeaders), [], 0).

group_headers(Headers) ->
    {Values, RevOrder} = lists:foldl(fun({K, V}, {Acc, Order}) ->
        Name = string:lowercase(string:trim(K)),
        Value = string:trim(V),
        case Name of
            <<"set-cookie">> ->
                {Acc, [{pair, Name, Value} | Order]};
            _ ->
                case maps:is_key(Name, Acc) of
                    false ->
                        {Acc#{Name => [Value]}, [Name | Order]};
                    true ->
                        {Acc#{Name => [Value | maps:get(Name, Acc)]}, Order}
                end
        end
    end, {#{}, []}, Headers),
    {_Emitted, RevPairs} = lists:foldl(fun
        ({pair, Name, Value}, {Emitted, Pairs}) ->
            {Emitted, [{Name, Value} | Pairs]};
        (Name, {Emitted, Pairs}) ->
            case sets:is_element(Name, Emitted) of
                true ->
                    {Emitted, Pairs};
                false ->
                    Joined = join_values(lists:reverse(maps:get(Name, Values))),
                    {sets:add_element(Name, Emitted),
                     [{Name, Joined} | Pairs]}
            end
    end, {sets:new([{version, 2}]), []}, lists:reverse(RevOrder)),
    lists:reverse(RevPairs).

%% Join a combinable field's values with ", ", dropping empty values —
%% the same rule headers_joined applies to the derived fields, kept in
%% parity so the surfaced set and content_encoding cannot disagree.
join_values(Values) ->
    Kept = [V || V <- Values, V =/= <<>>],
    iolist_to_binary(lists:join(<<", ">>, Kept)).

collect_capped([], Acc, _Size) ->
    {lists:reverse(Acc), false};
collect_capped([{Name, Value} | Rest], Acc, Size) ->
    PairSize = byte_size(Name) + byte_size(Value) + 2,
    case length(Acc) >= ?MAX_HEADER_PAIRS
         orelse Size + PairSize > ?MAX_HEADERS_BYTES of
        true ->
            {lists:reverse(Acc), true};
        false ->
            collect_capped(Rest, [{Name, Value} | Acc], Size + PairSize)
    end.

read_body(Client, MaxBytes, Acc, Dropped) ->
    Remaining = MaxBytes - byte_size(Acc),
    case Remaining =< 0 andalso Dropped of
        true ->
            hackney:close(Client),
            {ok, Acc, Dropped};
        false ->
            case hackney:stream_body(Client) of
                {ok, Chunk} ->
                    {Acc2, Dropped2} = append_capped(Acc, Chunk, Remaining),
                    read_body(Client, MaxBytes, Acc2, Dropped orelse Dropped2);
                done ->
                    hackney:close(Client),
                    {ok, Acc, Dropped};
                {error, Reason} ->
                    {error, format_reason(Reason)}
            end
    end.

append_capped(Acc, Chunk, Remaining) ->
    ChunkSize = byte_size(Chunk),
    case ChunkSize =< Remaining of
        true -> {<<Acc/binary, Chunk/binary>>, false};
        false -> {<<Acc/binary, Chunk:Remaining/binary>>, true}
    end.

header(Headers, Name) ->
    Pred = fun({K, _}) -> string:lowercase(K) =:= string:lowercase(Name) end,
    case lists:search(Pred, Headers) of
        {value, {_, Value}} -> Value;
        false -> <<>>
    end.

%% Collect all values for a repeated header (e.g. multiple Content-Encoding
%% headers) joined with ", " per RFC 9110. Unlike group_headers (the
%% surfaced, capped set) this runs over the UNCAPPED list for the derived
%% fields — content-encoding must survive even when the surfaced set is
%% cut by the caps — and shares the same drop-empty join rule (see
%% join_values).
headers_joined(Headers, Name) ->
    Target = string:lowercase(Name),
    Values = [string:trim(V) || {K, V} <- Headers,
              string:lowercase(K) =:= Target,
              string:trim(V) =/= <<>>],
    iolist_to_binary(lists:join(<<", ">>, Values)).

format_reason(Reason) ->
    unicode:characters_to_binary(io_lib:format("~tp", [Reason])).

%% Boundedly inflate a complete, already-wire-capped gzip/deflate body.
%%
%% The caller (`web_fetch`) advertises `Accept-Encoding: gzip, deflate`, so
%% origins may answer compressed even though bounded_request's MaxBytes bounds
%% only the COMPRESSED wire bytes; a decompression bomb would otherwise
%% expand post-receipt without bound. Like the wire cap, over-cap here
%% TRUNCATES ({ok, {Out, true}}) instead of erroring — the model sees
%% raw_truncated and knows the tail is gone.
%%
%% Memory is bounded BY ZLIB ITSELF, not by our own slicing: the whole
%% (wire-capped) body is enqueued once and `safeInflate` then returns at
%% most one fixed 16 KiB output chunk per call (the NIF's output chunk
%% size — probe-verified on a 1000:1 bomb), with the accumulated size
%% checked after every call. Peak cost is MaxOut plus one 16 KiB chunk
%% (the chunk that crosses the cap), independent of the stream's
%% compression ratio.
%%
%% truncated=true means the DOCUMENT is incomplete: either the decompressed
%% size crossed MaxOut (output cut there) or the compressed stream ended
%% without its terminator (cut upstream — e.g. a wire-truncated body whose
%% connection still closed cleanly). The verdict comes from `inflateEnd`,
%% NOT from safeInflate's {finished, _}, which is SPURIOUS when the input
%% runs dry mid-stream (zlib maps the no-progress condition to finished;
%% probe-verified) and so only means "no more output will come".
%%
%% Encoding is the normalized lowercase Content-Encoding token: "gzip",
%% "x-gzip", or "deflate". All use zlib auto-detection (windowBits 15+32,
%% which accepts both gzip and zlib-wrapped streams); a `deflate` token that
%% fails there is retried as RAW deflate (windowBits -15) — servers that
%% send RFC 1951 bytes under the `deflate` token. Only the FIRST gzip member
%% of a multi-member stream is decoded (zlib stops at the first member end;
%% HTTP origins emit single members), and trailing bytes after a complete
%% member are ignored. An empty body carries no member to decode and passes
%% through untouched (e.g. 204 with a stale header).
inflate_bounded(<<>>, _Encoding, _MaxOut) ->
    {ok, {<<>>, false}};
inflate_bounded(Body, Encoding0, MaxOut) ->
    Encoding = case Encoding0 of
        <<"x-gzip">> -> <<"gzip">>;
        E -> E
    end,
    try
        case run_inflate(Body, MaxOut, 47) of
            {error, _} when Encoding =:= <<"deflate">> ->
                run_inflate(Body, MaxOut, -15);
            Outcome -> Outcome
        end
    catch
        Class:Reason -> {error, format_reason({Class, Reason})}
    end.

run_inflate(Body, MaxOut, Wbits) ->
    Z = zlib:open(),
    try
        ok = zlib:inflateInit(Z, Wbits),
        case drain(Z, Body, MaxOut, <<>>) of
            {ok, Acc, cut} ->
                {ok, {Acc, true}};
            {ok, Acc, drained} ->
                %% The authoritative completeness verdict: inflateEnd
                %% succeeds only when end-of-stream was reached (its
                %% data_error here is expected for an incomplete stream,
                %% caught by `case catch`, never leaked as a crash).
                case catch zlib:inflateEnd(Z) of
                    ok -> {ok, {Acc, false}};
                    _ -> {ok, {Acc, true}}
                end
        end
    catch
        error:data_error -> {error, <<"corrupt compressed stream">>};
        Class:Reason -> {error, format_reason({Class, Reason})}
    after
        %% close/1 frees the stream even when inflateInit or inflate failed;
        %% guarded so a close fault cannot mask the outcome above.
        catch zlib:close(Z)
    end.

%% Drains the enqueued body through fixed-size output chunks until the
%% stream runs dry ({finished, _} — possibly spurious, see module notes)
%% or the accumulated output crosses MaxOut (cut there). The third tuple
%% element records which.
drain(Z, Body, MaxOut, Acc) ->
    case zlib:safeInflate(Z, Body) of
        {finished, Out} -> step(Z, Out, MaxOut, Acc, true);
        {continue, Out} -> step(Z, Out, MaxOut, Acc, false);
        %% We never negotiate preset dictionaries; treat one as corruption.
        {need_dictionary, _, _} -> erlang:error(data_error)
    end.

step(_Z, Out, MaxOut, Acc, true = _Dry) ->
    Acc2 = <<Acc/binary, (iolist_to_binary(Out))/binary>>,
    case byte_size(Acc2) > MaxOut of
        true ->
            <<Kept:MaxOut/binary, _/binary>> = Acc2,
            {ok, Kept, cut};
        false ->
            {ok, Acc2, drained}
    end;
step(Z, Out, MaxOut, Acc, false) ->
    Acc2 = <<Acc/binary, (iolist_to_binary(Out))/binary>>,
    case byte_size(Acc2) > MaxOut of
        true ->
            <<Kept:MaxOut/binary, _/binary>> = Acc2,
            {ok, Kept, cut};
        false ->
            drain(Z, [], MaxOut, Acc2)
    end.

%% Resolve a hostname (or IP literal) to all its addresses, as printable
%% strings ("127.0.0.1", "::1"). The Gleam side applies the private-range
%% policy. Errors are formatted binaries.
resolve_host(Host) ->
    HostList = unicode:characters_to_list(Host),
    Addresses = lists:usort(lists:flatten([
        resolve_family(HostList, inet),
        resolve_family(HostList, inet6)
    ])),
    case Addresses of
        [] -> {error, <<"could not resolve host">>};
        _ -> {ok, Addresses}
    end.

resolve_family(Host, Family) ->
    case inet:getaddr(Host, Family) of
        {ok, Addr} ->
            [unicode:characters_to_binary(inet:ntoa(Addr))];
        {error, _} -> []
    end.

%% Arbitrary response bytes -> valid UTF-8 binary.
%% - Pure valid UTF-8 takes the fast zero-copy path.
%% - A trailing incomplete multi-byte UTF-8 sequence (e.g. cut at MaxBytes)
%%   drops only the unfinished trailing bytes instead of corrupting earlier
%%   valid UTF-8 in the document.
%% - Any invalid UTF-8 byte is decoded as Latin-1 (U+0000..U+00FF), with
%%   0x80-0x9F mapped per WHATWG Windows-1252 (smart quotes, dashes, euro)
%%   so legacy-encoded or mixed pages decode legibly and never crash
%%   downstream HTML parsing or JSON encoding.
to_text_lossy(Bin) when is_binary(Bin) ->
    case unicode:characters_to_binary(Bin, utf8) of
        Text when is_binary(Text) -> Text;
        {incomplete, Good, _Rest} -> Good;
        {error, Good, <<Bad, Rest/binary>>} ->
            to_text_lossy_loop(Rest, [lossy_byte(Bad), Good])
    end.

to_text_lossy_loop(<<>>, Acc) ->
    iolist_to_binary(lists:reverse(Acc));
to_text_lossy_loop(Bin, Acc) ->
    case unicode:characters_to_binary(Bin, utf8) of
        Text when is_binary(Text) ->
            iolist_to_binary(lists:reverse([Text | Acc]));
        {incomplete, Good, _Rest} ->
            iolist_to_binary(lists:reverse([Good | Acc]));
        {error, Good, <<Bad, Rest/binary>>} ->
            to_text_lossy_loop(Rest, [lossy_byte(Bad), Good | Acc])
    end.

lossy_byte(16#80) -> <<16#20AC/utf8>>;
lossy_byte(16#82) -> <<16#201A/utf8>>;
lossy_byte(16#83) -> <<16#0192/utf8>>;
lossy_byte(16#84) -> <<16#201E/utf8>>;
lossy_byte(16#85) -> <<16#2026/utf8>>;
lossy_byte(16#86) -> <<16#2020/utf8>>;
lossy_byte(16#87) -> <<16#2021/utf8>>;
lossy_byte(16#88) -> <<16#02C6/utf8>>;
lossy_byte(16#89) -> <<16#2030/utf8>>;
lossy_byte(16#8A) -> <<16#0160/utf8>>;
lossy_byte(16#8B) -> <<16#2039/utf8>>;
lossy_byte(16#8C) -> <<16#0152/utf8>>;
lossy_byte(16#8E) -> <<16#017D/utf8>>;
lossy_byte(16#91) -> <<16#2018/utf8>>;
lossy_byte(16#92) -> <<16#2019/utf8>>;
lossy_byte(16#93) -> <<16#201C/utf8>>;
lossy_byte(16#94) -> <<16#201D/utf8>>;
lossy_byte(16#95) -> <<16#2022/utf8>>;
lossy_byte(16#96) -> <<16#2013/utf8>>;
lossy_byte(16#97) -> <<16#2014/utf8>>;
lossy_byte(16#98) -> <<16#02DC/utf8>>;
lossy_byte(16#99) -> <<16#2122/utf8>>;
lossy_byte(16#9A) -> <<16#0161/utf8>>;
lossy_byte(16#9B) -> <<16#203A/utf8>>;
lossy_byte(16#9C) -> <<16#0153/utf8>>;
lossy_byte(16#9E) -> <<16#017E/utf8>>;
lossy_byte(16#9F) -> <<16#0178/utf8>>;
lossy_byte(Bad) -> <<Bad/utf8>>.
