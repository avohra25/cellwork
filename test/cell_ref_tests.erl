-module(cell_ref_tests).
-include_lib("eunit/include/eunit.hrl").

parse_test_() ->
    [?_assertEqual({ok, {1, 1}}, cell_ref:parse("A1")),
     ?_assertEqual({ok, {2, 3}}, cell_ref:parse(<<"b3">>)),
     ?_assertEqual({ok, {27, 10}}, cell_ref:parse("AA10")),
     ?_assertEqual({ok, {16384, 1048576}}, cell_ref:parse("XFD1048576")),
     ?_assertEqual({ok, {2, 3, true, false}}, cell_ref:parse_ref("$B3")),
     ?_assertEqual({ok, {2, 3, false, true}}, cell_ref:parse_ref("B$3")),
     ?_assertEqual(error, cell_ref:parse("XFE1")),
     ?_assertEqual(error, cell_ref:parse("A0")),
     ?_assertEqual(error, cell_ref:parse("A01")),
     ?_assertEqual(error, cell_ref:parse("A1048577")),
     ?_assertEqual(error, cell_ref:parse("ABCD1")),
     ?_assertEqual(error, cell_ref:parse("1A")),
     ?_assertEqual(error, cell_ref:parse("")),
     ?_assertEqual(error, cell_ref:parse("A1B"))].

letters_roundtrip_test() ->
    [?assertEqual(N, cell_ref:letters_to_col(cell_ref:col_to_letters(N)))
     || N <- lists:seq(1, 20000)],
    ?assertEqual("Z", cell_ref:col_to_letters(26)),
    ?assertEqual("AA", cell_ref:col_to_letters(27)),
    ?assertEqual("AZ", cell_ref:col_to_letters(52)),
    ?assertEqual("XFD", cell_ref:col_to_letters(16384)).

to_string_test() ->
    ?assertEqual("C7", cell_ref:to_string({3, 7})),
    ?assertEqual("$C$7", cell_ref:to_string({3, 7}, {true, true})).

normalize_test() ->
    ?assertEqual({{1, 2}, {3, 5}}, cell_ref:normalize_range({3, 2}, {1, 5})).
