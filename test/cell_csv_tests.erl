-module(cell_csv_tests).
-include_lib("eunit/include/eunit.hrl").

parse_test_() ->
    P = fun(S) -> {ok, Rows} = cell_csv:parse(S), Rows end,
    [?_assertEqual([], P("")),
     ?_assertEqual([[<<"a">>, <<"b">>]], P("a,b")),
     ?_assertEqual([[<<"a">>, <<"b">>]], P("a,b\n")),
     ?_assertEqual([[<<"a">>], [<<"b">>]], P("a\r\nb\r\n")),
     ?_assertEqual([[<<>>, <<>>, <<>>]], P(",,")),
     ?_assertEqual([[<<"x,y">>, <<"say \"hi\"">>]], P("\"x,y\",\"say \"\"hi\"\"\"")),
     ?_assertEqual([[<<"two\nlines">>, <<"z">>]], P("\"two\nlines\",z\n")),
     ?_assertEqual([[<<"">>]], P("\"\"")),
     ?_assertEqual([[<<"héllo"/utf8>>]], P(<<"héllo"/utf8>>)),
     ?_assertEqual({error, {unterminated_quote, 2}}, cell_csv:parse("ok\n\"open,\nmore"))].

encode_test_() ->
    [?_assertEqual(<<"a,b\n">>, cell_csv:encode([[<<"a">>, <<"b">>]])),
     ?_assertEqual(<<"\"x,y\",\"q\"\"\"\n">>, cell_csv:encode([[<<"x,y">>, <<"q\"">>]])),
     ?_assertEqual(<<"\" pad\",\n">>, cell_csv:encode([[<<" pad">>, <<>>]]))].

roundtrip_test() ->
    rand:seed(exsss, {7, 8, 9}),
    Alphabet = "ab ,\"\n=1",
    lists:foreach(
      fun(_) ->
              Rows = [[list_to_binary([lists:nth(rand:uniform(length(Alphabet)), Alphabet)
                                       || _ <- lists:seq(1, rand:uniform(5) - 1)])
                       || _ <- lists:seq(1, rand:uniform(4))]
                      || _ <- lists:seq(1, rand:uniform(4))],
              %% A lone empty field on a row is indistinguishable from a blank line.
              case lists:any(fun(R) -> R =:= [<<>>] end, Rows) of
                  true -> ok;
                  false -> ?assertEqual({ok, Rows}, cell_csv:parse(cell_csv:encode(Rows)))
              end
      end, lists:seq(1, 1000)).

load_test() ->
    {ok, S} = cell_csv:load("x,2\ny,\"=B1*3\"\nsum,\"=SUM(B1:B2)\"\n"),
    ?assertEqual(8.0, cell_sheet:get(S, "B3")),
    ?assertEqual(<<"y">>, cell_sheet:get(S, "A2")),
    ?assertEqual(<<"x,2\ny,6\nsum,8\n">>, cell_csv:export_values(S)),
    ?assertEqual(<<"x,2\ny,=B1*3\nsum,=SUM(B1:B2)\n">>, cell_csv:export_inputs(S)),
    {ok, S2} = cell_csv:load(cell_csv:export_inputs(S)),
    ?assertEqual(cell_sheet:cells(S), cell_sheet:cells(S2)).

load_errors_test_() ->
    [?_assertMatch({error, {syntax, {2, 1}, _}}, cell_csv:load("1,=1+\n")),
     ?_assertMatch({error, {file, "/nonexistent.csv", enoent}},
                   cell_csv:load_file("/nonexistent.csv"))].

example_test() ->
    {ok, S} = cell_csv:load_file(filename:join([code:lib_dir(cellwork), "..", "..", "..", "..",
                                                "examples", "budget.csv"])),
    ?assertEqual(<<"2611">>, cell_sheet:display(S, "B7")),
    ?assertEqual(<<"31332">>, cell_sheet:display(S, "C7")),
    ?assertEqual(<<"100">>, cell_sheet:display(S, "D7")),
    ?assertEqual(<<"1">>, cell_sheet:display(S, "B8")).
