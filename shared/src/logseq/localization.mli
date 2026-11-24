val resolve : string -> string -> string
val translate : language:string -> system_language:string -> string -> string
val journal_date : language:string -> system_language:string -> current_year:int -> int -> string * string
val journal_day_of_title : language:string -> system_language:string -> current_year:int -> string -> int option
