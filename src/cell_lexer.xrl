%% Tokenizer for spreadsheet formulas (the text after the leading `=`).

Definitions.

D  = [0-9]
L  = [A-Za-z]
WS = [\s\t\r\n]

Rules.

{D}+(\.{D}*)?([eE][+-]?{D}+)? :
    number(TokenLine, TokenChars).
\.{D}+([eE][+-]?{D}+)? :
    number(TokenLine, TokenChars).
\$?{L}+\$?{D}+ :
    {token, {ref, TokenLine, TokenChars}}.
{L}[A-Za-z0-9_.]* :
    {token, {ident, TokenLine, string:uppercase(TokenChars)}}.
"([^"]|"")*" :
    {token, {string, TokenLine, unquote(TokenChars)}}.
#(DIV/0!|VALUE!|REF!|NAME\?|N/A|NUM!|CYCLE!) :
    {token, {errlit, TokenLine, cell_value:error_from_string(TokenChars)}}.
<> : {token, {'<>', TokenLine}}.
<= : {token, {'<=', TokenLine}}.
>= : {token, {'>=', TokenLine}}.
[=<>&+\-*/^%(),:] :
    {token, {list_to_atom(TokenChars), TokenLine}}.
{WS}+ : skip_token.

Erlang code.

number(Line, Chars) ->
    case cell_value:parse_number(Chars) of
        {ok, F} -> {token, {number, Line, F}};
        error -> {error, "number out of range: " ++ Chars}
    end.

unquote([$" | Rest]) ->
    Body = lists:droplast(Rest),
    unicode:characters_to_binary(string:replace(Body, "\"\"", "\"", all)).
