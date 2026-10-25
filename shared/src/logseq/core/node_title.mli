val is_page : Datascript.db -> int -> bool
val is_class : Datascript.db -> int -> bool
val is_property : Datascript.db -> int -> bool
val can_delete : ?now:int -> Datascript.db -> int -> bool
val can_edit : Datascript.db -> int -> bool
val can_rename_page : Datascript.db -> int -> bool
val name : string -> string
val validate : Datascript.db -> int -> string -> (unit, string) result
