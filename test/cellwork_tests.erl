-module(cellwork_tests).
-include_lib("eunit/include/eunit.hrl").

tmp(Name, Body) ->
    Path = filename:join("/tmp", "cellwork_test_" ++ os:getpid() ++ "_" ++ Name),
    ok = file:write_file(Path, Body),
    Path.

out({Code, IoData}) -> {Code, unicode:characters_to_binary(IoData)}.

render_test() ->
    {ok, S} = cell_csv:load("name,qty\nbolts,\"=2*6\"\nnuts,7\n"),
    ?assertEqual(<<"  | A     | B  \n"
                   "--+-------+----\n"
                   "1 | name  | qty\n"
                   "2 | bolts |  12\n"
                   "3 | nuts  |   7\n">>,
                 unicode:characters_to_binary(cellwork:render(S))),
    ?assertEqual(<<"(empty sheet)\n">>,
                 unicode:characters_to_binary(cellwork:render(cell_sheet:new()))).

commands_test_() ->
    Good = tmp("good.csv", "1,\"=A1*10\"\n"),
    Bad = tmp("bad.csv", "=1/0,\"=A1+1\",ok\n"),
    [?_assertEqual({0, <<"1,10\n">>}, out(cellwork:run(["eval", Good, "--csv"]))),
     ?_assertEqual({0, <<"10\n">>}, out(cellwork:run(["get", Good, "B1"]))),
     ?_assertMatch({2, <<"error: bad cell reference", _/binary>>},
                   out(cellwork:run(["get", Good, "nope"]))),
     ?_assertEqual({0, <<"ok: no errors\n">>}, out(cellwork:run(["check", Good]))),
     ?_assertEqual({1, <<"A1: #DIV/0!\nB1: #DIV/0!\n">>}, out(cellwork:run(["check", Bad]))),
     ?_assertMatch({2, <<"error: /nonexistent.csv: ", _/binary>>},
                   out(cellwork:run(["eval", "/nonexistent.csv"]))),
     ?_assertMatch({0, <<"usage:", _/binary>>}, out(cellwork:run([]))),
     ?_assertMatch({2, <<"usage:", _/binary>>}, out(cellwork:run(["frobnicate"])))].

cycle_example_test() ->
    Path = filename:join([code:lib_dir(cellwork), "..", "..", "..", "..",
                          "examples", "cycle.csv"]),
    {1, Out} = out(cellwork:run(["check", Path])),
    ?assertEqual(<<"B1: #CYCLE!\nB2: #CYCLE!\n">>, Out).
