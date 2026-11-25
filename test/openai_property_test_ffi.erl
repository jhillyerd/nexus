%% Test-only offline loopback TCP one-shot responder for verifying non-200 HTTP
%% status handling in `nexus/openai.stream` without external network access.
-module(openai_property_test_ffi).

-export([serve_once/1]).

serve_once(ResponseBin) ->
    {ok, ListenSock} = gen_tcp:listen(0, [
        binary,
        {ip, {127, 0, 0, 1}},
        {packet, raw},
        {active, false},
        {reuseaddr, true}
    ]),
    {ok, Port} = inet:port(ListenSock),
    spawn(fun() ->
        case gen_tcp:accept(ListenSock, 5000) of
            {ok, Sock} ->
                read_headers(Sock, <<>>),
                _ = gen_tcp:send(Sock, ResponseBin),
                _ = gen_tcp:shutdown(Sock, write),
                _ = gen_tcp:recv(Sock, 0, 1000),
                _ = gen_tcp:close(Sock);
            _ ->
                ok
        end,
        _ = gen_tcp:close(ListenSock)
    end),
    Port.

read_headers(Sock, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        nomatch ->
            case gen_tcp:recv(Sock, 0, 2000) of
                {ok, Data} -> read_headers(Sock, <<Acc/binary, Data/binary>>);
                _ -> ok
            end;
        _ ->
            ok
    end.
