-module(cell_eval_tests).
-include_lib("eunit/include/eunit.hrl").

%% A1=10, A2="x", A3=TRUE, A4 blank, A5="7", B1=#DIV/0!, B2=-3.5
grid({1, 1}) -> 10.0;
grid({1, 2}) -> <<"x">>;
grid({1, 3}) -> true;
grid({1, 5}) -> <<"7">>;
grid({2, 1}) -> {error, div0};
grid({2, 2}) -> -3.5;
grid(_) -> empty.

e(Src) ->
    {ok, Ast} = cell_formula:parse(Src),
    cell_value:display(cell_eval:eval(Ast, fun grid/1)).

arithmetic_test_() ->
    [?_assertEqual(<<"7">>, e("1+2*3")),
     ?_assertEqual(<<"4">>, e("-2^2")),
     ?_assertEqual(<<"0.3">>, e("0.1+0.2")),
     ?_assertEqual(<<"0.05">>, e("5%")),
     ?_assertEqual(<<"2.5">>, e("5/2")),
     ?_assertEqual(<<"#DIV/0!">>, e("1/0")),
     ?_assertEqual(<<"#DIV/0!">>, e("0^-1")),
     ?_assertEqual(<<"#NUM!">>, e("(-8)^0.5")),
     ?_assertEqual(<<"#NUM!">>, e("10^400")),
     ?_assertEqual(<<"17">>, e("A5+A1")),     % numeric text coerces
     ?_assertEqual(<<"11">>, e("A3+A1")),     % TRUE is 1
     ?_assertEqual(<<"10">>, e("A4+A1")),     % blank is 0
     ?_assertEqual(<<"#VALUE!">>, e("A2+1")),
     ?_assertEqual(<<"#DIV/0!">>, e("B1+1")),
     ?_assertEqual(<<"#VALUE!">>, e("A1:A3")),
     ?_assertEqual(<<"#VALUE!">>, e("A1:A3+1")),
     ?_assertEqual(<<"0">>, e("A4")),
     ?_assertEqual(<<"#NAME?">>, e("nope+1")),
     ?_assertEqual(<<"#REF!">>, e("#REF!"))].

text_and_compare_test_() ->
    [?_assertEqual(<<"10 apples">>, e("A1&\" apples\"")),
     ?_assertEqual(<<"TRUEx">>, e("A3&A2")),
     ?_assertEqual(<<"TRUE">>, e("\"abc\"=\"ABC\"")),
     ?_assertEqual(<<"TRUE">>, e("\"a\"<\"B\"")),
     ?_assertEqual(<<"TRUE">>, e("99<\"1\"")),      % numbers sort before text
     ?_assertEqual(<<"TRUE">>, e("\"z\"<FALSE")),   % text before booleans
     ?_assertEqual(<<"TRUE">>, e("A4=0")),
     ?_assertEqual(<<"TRUE">>, e("A4=\"\"")),
     ?_assertEqual(<<"FALSE">>, e("A1<>10")),
     ?_assertEqual(<<"#DIV/0!">>, e("B1=1"))].

aggregate_test_() ->
    [?_assertEqual(<<"10">>, e("SUM(A1:A5)")),           % text and bools in ranges skipped
     ?_assertEqual(<<"10">>, e("SUM(A1, A3, A5)")),          % cell text and bools skipped
     ?_assertEqual(<<"18">>, e("SUM(A1,TRUE,\"7\")")),       % direct arguments coerce
     ?_assertEqual(<<"#VALUE!">>, e("SUM(\"x\")")),
     ?_assertEqual(<<"#DIV/0!">>, e("SUM(A1:B2)")),       % errors propagate
     ?_assertEqual(<<"0">>, e("SUM()")),
     ?_assertEqual(<<"-35">>, e("PRODUCT(A1,B2)")),
     ?_assertEqual(<<"3.25">>, e("AVERAGE(A1,B2)")),
     ?_assertEqual(<<"#DIV/0!">>, e("AVERAGE(A2:A4)")),
     ?_assertEqual(<<"-3.5">>, e("MIN(A1,B2,4)")),
     ?_assertEqual(<<"10">>, e("MAX(A1:A5)")),
     ?_assertEqual(<<"0">>, e("MAX(A2:A4)")),
     ?_assertEqual(<<"1">>, e("COUNT(A1:A5)")),
     ?_assertEqual(<<"3">>, e("COUNT(A1:A5, 2, \"3\")")),
     ?_assertEqual(<<"4">>, e("COUNTA(A1:A5)")),
     ?_assertEqual(<<"10xTRUE7">>, e("CONCAT(A1:A5)"))].

logic_test_() ->
    [?_assertEqual(<<"big">>, e("IF(A1>5,\"big\",\"small\")")),
     ?_assertEqual(<<"FALSE">>, e("IF(A1<5,1)")),
     ?_assertEqual(<<"ok">>, e("IF(TRUE,\"ok\",1/0)")),   % untaken branch not evaluated
     ?_assertEqual(<<"#VALUE!">>, e("IF(A2,1,2)")),
     ?_assertEqual(<<"fallback">>, e("IFERROR(B1,\"fallback\")")),
     ?_assertEqual(<<"10">>, e("IFERROR(A1,0)")),
     ?_assertEqual(<<"TRUE">>, e("ISERROR(1/0)")),
     ?_assertEqual(<<"TRUE">>, e("ISBLANK(A4)")),
     ?_assertEqual(<<"FALSE">>, e("ISBLANK(A1)")),
     ?_assertEqual(<<"TRUE">>, e("ISNUMBER(A1)")),
     ?_assertEqual(<<"TRUE">>, e("ISTEXT(A5)")),
     ?_assertEqual(<<"TRUE">>, e("AND(A1,A3)")),
     ?_assertEqual(<<"FALSE">>, e("AND(A1:A3,0)")),
     ?_assertEqual(<<"TRUE">>, e("OR(FALSE,A1)")),
     ?_assertEqual(<<"#VALUE!">>, e("AND(A2)")),
     ?_assertEqual(<<"FALSE">>, e("NOT(A1)"))].

math_and_text_test_() ->
    [?_assertEqual(<<"3.5">>, e("ABS(B2)")),
     ?_assertEqual(<<"-4">>, e("INT(B2)")),
     ?_assertEqual(<<"3">>, e("SQRT(9)")),
     ?_assertEqual(<<"#NUM!">>, e("SQRT(-1)")),
     ?_assertEqual(<<"1024">>, e("POWER(2,10)")),
     ?_assertEqual(<<"2">>, e("MOD(-7,3)")),
     ?_assertEqual(<<"-2">>, e("MOD(7,-3)")),
     ?_assertEqual(<<"#DIV/0!">>, e("MOD(1,0)")),
     ?_assertEqual(<<"2.35">>, e("ROUND(2.345,2)")),
     ?_assertEqual(<<"-3">>, e("ROUND(-2.5)")),
     ?_assertEqual(<<"1200">>, e("ROUND(1234,-2)")),
     ?_assertEqual(<<"5">>, e("LEN(\"héllo\")")),
     ?_assertEqual(<<"ABC">>, e("UPPER(\"abc\")")),
     ?_assertEqual(<<"abc">>, e("LOWER(\"ABC\")")),
     ?_assertEqual(<<"a b c">>, e("TRIM(\"  a  b c \")")),
     ?_assertEqual(<<"#VALUE!">>, e("ABS(1,2)")),
     ?_assertEqual(<<"#NAME?">>, e("NOSUCH(1)"))].

criteria_test_() ->
    G = fun({1, R}) -> lists:nth(R, [3.0, 8.0, <<"apple">>, <<"Apricot">>, 8.0, empty, <<"pear">>]);
           ({2, R}) when R =< 7 -> float(R * 10);
           (_) -> empty
        end,
    E = fun(Src) ->
                {ok, Ast} = cell_formula:parse(Src),
                cell_value:display(cell_eval:eval(Ast, G))
        end,
    [?_assertEqual(<<"2">>, E("COUNTIF(A1:A7,8)")),
     ?_assertEqual(<<"2">>, E("COUNTIF(A1:A7,\">5\")")),
     ?_assertEqual(<<"3">>, E("COUNTIF(A1:A7,\"<=8\")")),
     ?_assertEqual(<<"2">>, E("COUNTIF(A1:A7,\"ap*\")")),
     ?_assertEqual(<<"1">>, E("COUNTIF(A1:A7,\"p??r\")")),
     ?_assertEqual(<<"5">>, E("COUNTIF(A1:A7,\"<>a*\")")),   % blanks count as not matching
     ?_assertEqual(<<"2">>, E("COUNTIF(A1:A7,\"<b\")")),
     ?_assertEqual(<<"70">>, E("SUMIF(A1:A7,\"a*\",B1:B7)")),
     ?_assertEqual(<<"16">>, E("SUMIF(A1:A7,8)")),
     ?_assertEqual(<<"#VALUE!">>, E("SUMIF(A1:A7,8,B1:B2)"))].
