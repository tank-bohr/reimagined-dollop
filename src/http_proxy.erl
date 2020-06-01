-module(http_proxy).
-include_lib("kernel/include/logger.hrl").

-export([
  start/0,
  start/1
]).

-record(request, {
    uri,
    headers = []
}).

-define(TIMEOUT, 5000).

start() ->
    ok = logger:set_primary_config(level, debug),
    start(3128).

start(Port) ->
    {ok, ListenSocket} = gen_tcp:listen(Port, [
        binary,
        {packet, http},
        {active, false},
        {reuseaddr, true}
    ]),
    accept_loop(ListenSocket).

accept_loop(ListenSocket) ->
    ?LOG_DEBUG("Waiting for connections..."),
    {ok, ClientSocket} = gen_tcp:accept(ListenSocket),
    {ok, Request} = recv_loop(ClientSocket),
    ok = inet:setopts(ClientSocket, [{packet, raw}]),
    {ok, Socket} = tunnel(Request#request.uri),
    ok = gen_tcp:send(ClientSocket, <<"HTTP/1.1 200 OK\r\n\r\n">>),
    ok = proxy(ClientSocket, Socket),
    accept_loop(ListenSocket).

recv_loop(ClientSocket) ->
    recv_loop(ClientSocket, #request{}).

recv_loop(ClientSocket, #request{headers = Headers} = Request) ->
    case gen_tcp:recv(ClientSocket, 0) of
        {ok, {http_request, "CONNECT", Uri, _Version}} ->
            recv_loop(ClientSocket, Request#request{uri = Uri});
        {ok, {http_header, _, Name, _, Value}} ->
            recv_loop(ClientSocket, Request#request{headers = [{Name, Value} | Headers]});
        {ok, http_eoh} ->
            {ok, Request#request{headers = lists:reverse(Headers)}};
        Unexpected ->
            {unexpected, Unexpected}
    end.

tunnel({scheme, Host, PortStr}) ->
    Port = list_to_integer(PortStr),
    gen_tcp:connect(Host, Port, [{packet, raw}, {active, false}], ?TIMEOUT).

proxy(ClientSocket, Socket) ->
    spawn_link(fun() -> transfer(ClientSocket, Socket) end),
    spawn_link(fun() -> transfer(Socket, ClientSocket) end),
    ok.

transfer(From, To) ->
    case gen_tcp:recv(From, 0) of
        {ok, Data} ->
            ok = gen_tcp:send(To, Data),
            transfer(From, To);
        {error, _Error} ->
            ok
    end.
