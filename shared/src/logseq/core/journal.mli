(** Journal title formatting shared by graph reads, writes, and queries. *)
val default_format : string
val format_attr : string
val month_names : string list
val month_short : string array
val month_long : string array
val weekday_names : string array
val built_in_journal_title_formatters : string list
val journal_title_formatters : string option -> string list
type tok = TokYear of int | TokMonthNum | TokMonthName of int | TokDay | TokDayOrd | TokWeekday of int | TokLit of char
val tokens_of_formatter : string -> tok list
val ordinal_suffix : int -> string
val weekday_index : int * int * int -> int
val formatter_of_date : string -> int * int * int -> string
val int_to_journal_title : int -> string -> string
val valid_day : int -> bool
val format : Datascript.db -> string
val day_title : int -> string
val title : Datascript.db -> int -> string

val page_uuid : int -> string
