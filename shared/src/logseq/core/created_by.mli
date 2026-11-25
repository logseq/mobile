type identity = { uuid : string; username : string; email : string; full_name : string; avatar : string }
val property : string
val of_token : string -> identity option
val additions : identity -> Datascript.tx_report -> Datascript.tx_op list
