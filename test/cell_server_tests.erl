-module(cell_server_tests).
-include_lib("eunit/include/eunit.hrl").

server_test_() ->
    {foreach,
     fun() -> {ok, Pid} = cell_server:start_link(), Pid end,
     fun(Pid) -> unlink(Pid), cell_server:stop(Pid) end,
     [fun basic/1, fun notifications/1, fun batch/1, fun errors/1,
      fun dead_subscriber/1, fun unsubscribe/1, fun concurrent_writers/1]}.

basic(S) ->
    {ok, _} = cell_server:set(S, "A1", "21"),
    {ok, Changed} = cell_server:set(S, "B1", "=A1*2"),
    [?_assertEqual([{{2, 1}, 42.0}], Changed),
     ?_assertEqual(42.0, cell_server:get(S, "B1")),
     ?_assertEqual(<<"42">>, cell_server:display(S, "B1")),
     ?_assertEqual(<<"=A1*2">>, cell_server:input(S, "B1")),
     ?_assertEqual(2, cell_sheet:size(cell_server:snapshot(S)))].

notifications(S) ->
    ok = cell_server:subscribe(S),
    ok = cell_server:subscribe(S),              % idempotent
    {ok, _} = cell_server:set(S, "B1", "=A1+1"),
    M1 = recv(),
    {ok, _} = cell_server:set(S, "A1", "4"),
    M2 = recv(),
    {ok, []} = cell_server:set(S, "A1", "4"),   % no change, no message
    M3 = recv(),
    Subs = cell_server:subscribers(S),
    Me = self(),
    [?_assertEqual({cellwork, S, [{{2, 1}, 1.0}]}, M1),
     ?_assertEqual({cellwork, S, [{{1, 1}, 4.0}, {{2, 1}, 5.0}]}, M2),
     ?_assertEqual(none, M3),
     ?_assertEqual([Me], Subs)].

batch(S) ->
    ok = cell_server:subscribe(S),
    {ok, _} = cell_server:set_many(S, [{"A1", "1"}, {"A2", "2"}, {"A3", "=A1+A2"}]),
    {cellwork, S, Changed} = recv(),
    Extra = recv(),
    [?_assertEqual([{{1, 1}, 1.0}, {{1, 2}, 2.0}, {{1, 3}, 3.0}], lists:sort(Changed)),
     ?_assertEqual(none, Extra)].

errors(S) ->
    ok = cell_server:subscribe(S),
    R1 = cell_server:set_many(S, [{"A1", "1"}, {"A2", "=SUM("}]),
    R2 = cell_server:set(S, "ZZZZ1", "1"),
    A1 = cell_server:get(S, "A1"),
    Msg = recv(),
    [?_assertMatch({error, {syntax, {1, 2}, _}}, R1),
     ?_assertMatch({error, {bad_ref, _}}, R2),
     ?_assertEqual(empty, A1),
     ?_assertEqual(none, Msg)].

dead_subscriber(S) ->
    Parent = self(),
    Pid = spawn(fun() -> ok = cell_server:subscribe(S), Parent ! subscribed,
                         receive stop -> ok end end),
    receive subscribed -> ok end,
    Before = cell_server:subscribers(S),
    MRef = monitor(process, Pid),
    Pid ! stop,
    receive {'DOWN', MRef, _, _, _} -> ok end,
    After = cell_server:subscribers(S),   % call is ordered after the DOWN
    [?_assertEqual([Pid], Before), ?_assertEqual([], After)].

unsubscribe(S) ->
    ok = cell_server:subscribe(S),
    ok = cell_server:unsubscribe(S),
    ok = cell_server:unsubscribe(S),
    {ok, _} = cell_server:set(S, "A1", "1"),
    Msg = recv(),
    Subs = cell_server:subscribers(S),
    [?_assertEqual(none, Msg), ?_assertEqual([], Subs)].

concurrent_writers(S) ->
    %% Many processes edit disjoint cells while a SUM reads them all; the
    %% server serialises the edits so the total is exact.
    {ok, _} = cell_server:set(S, "B1", "=SUM(A1:A50)"),
    Parent = self(),
    Pids = [spawn(fun() ->
                          [{ok, _} = cell_server:set(S, {1, N}, integer_to_list(K))
                           || K <- lists:seq(1, 20)],
                          Parent ! {done, self()}
                  end) || N <- lists:seq(1, 50)],
    [receive {done, P} -> ok end || P <- Pids],
    Total = cell_server:get(S, "B1"),
    [?_assertEqual(1000.0, Total)].

recv() ->
    receive {cellwork, _, _} = M -> M after 50 -> none end.
