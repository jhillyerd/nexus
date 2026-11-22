%% M3 tool-adapter FFI: bounded buffered GETs and host resolution for the
%% http_fetch SSRF guard. Body size is enforced here (not in Gleam) so a
%% multi-gigabyte response cannot be materialised before truncation.
-module(nexus_net_ffi).

-export([bounded_get/4, resolve_host/1, to_text_lossy/1, inflate_bounded/3]).

%% GET with connect/receive timeouts and a hard byte cap. Does NOT follow
%% redirects (policy — including re-validating every hop against the SSRF
%% guard — lives in nexus/http_fetch.gleam). Returns:
%%   {ok, {Status, ContentType, Body, Truncated}} | {error, Reason}
%% where ContentType is <<>> when absent and Truncated is true when the body
%% was cut at MaxBytes.
%%
%% The whole hop runs under a HARD total deadline (see bounded_get/4): the
%% whole call — TLS handshake included — must return to the caller within
%% it. bounded_get_inner is the pre-deadline body, unchanged.
bounded_get(Url, Headers, MaxBytes, TimeoutMs) ->
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
        Result = try bounded_get_inner(Url, Headers, MaxBytes, TimeoutMs) of
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

bounded_get_inner(Url, Headers, MaxBytes, TimeoutMs) ->
    Opts = [{connect_timeout, TimeoutMs}, {recv_timeout, TimeoutMs}],
    case hackney:request(get, Url, Headers, <<>>, Opts) of
        {ok, Status, RespHeaders, Client} ->
            ContentType = header(RespHeaders, <<"content-type">>),
            ContentEncoding =
                string:lowercase(headers_joined(RespHeaders, <<"content-encoding">>)),
            Location = header(RespHeaders, <<"location">>),
            case read_body(Client, MaxBytes, <<>>, false) of
                {ok, Body, Truncated} ->
                    {ok, {fetch_response, Status, ContentType, Location, Body,
                          Truncated, Url, ContentEncoding}};
                {error, Reason} ->
                    hackney:close(Client),
                    {error, format_reason(Reason)}
            end;
        {error, Reason} ->
            {error, format_reason(Reason)}
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
%% headers) joined with ", " per RFC 9110.
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
%% origins may answer compressed even though bounded_get's MaxBytes bounds
%% only the COMPRESSED wire bytes; a decompression bomb would otherwise
%% expand post-receipt without bound. Like the wire cap, over-cap here
%% TRUNCATES ({ok, {Out, true}}) instead of erroring — the model sees
%% raw_truncated and knows the tail is gone. Memory stays bounded because
%% the compressed input is fed to zlib in fixed slices with the accumulated
%% output checked after every slice: peak cost is MaxOut plus one slice's
%% worst-case expansion.
%%
%% Encoding is the normalized lowercase Content-Encoding token: "gzip",
%% "x-gzip", or "deflate". All use zlib auto-detection (windowBits 15+32,
%% which accepts both gzip and zlib-wrapped streams); a `deflate` token that
%% fails there is retried as RAW deflate (windowBits -15) — servers that
%% send RFC 1951 bytes under the `deflate` token. Only the FIRST gzip member
%% of a multi-member stream is decoded (zlib ignores trailing member bytes;
%% HTTP origins emit single members). An empty body carries no member to
%% decode and passes through untouched (e.g. 204 with a stale header).
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

-define(INFLATE_SLICE, 4096).

run_inflate(Body, MaxOut, Wbits) ->
    Z = zlib:open(),
    try
        ok = zlib:inflateInit(Z, Wbits),
        feed_inflate(Z, Body, MaxOut, <<>>)
    catch
        error:data_error -> {error, <<"corrupt compressed stream">>};
        Class:Reason -> {error, format_reason({Class, Reason})}
    after
        %% close/1 frees the stream even when inflateInit or inflate failed;
        %% guarded so a close fault cannot mask the outcome above.
        catch zlib:close(Z)
    end.

feed_inflate(_Z, <<>>, _MaxOut, Acc) ->
    {ok, {Acc, false}};
feed_inflate(Z, Body, MaxOut, Acc) ->
    SliceSize = erlang:min(?INFLATE_SLICE, byte_size(Body)),
    <<Slice:SliceSize/binary, Rest/binary>> = Body,
    Out = iolist_to_binary(zlib:inflate(Z, Slice)),
    Acc2 = <<Acc/binary, Out/binary>>,
    case byte_size(Acc2) > MaxOut of
        true ->
            <<Kept:MaxOut/binary, _/binary>> = Acc2,
            {ok, {Kept, true}};
        false ->
            feed_inflate(Z, Rest, MaxOut, Acc2)
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
