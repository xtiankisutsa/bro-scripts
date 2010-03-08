@load global-ext
@load http-ext

module HTTP;

export {
	# If set to T, this will split inbound and outbound transactions
	# into separate files.  F merges everything into a single file.
	const split_log_file = T &redef;
	
	# Which http transactions to log.
	# Choices are: Inbound, Outbound, All
	const logging = All &redef;
	
	# This is list of subnets containing web servers that you'd like to log their
	# traffic regardless of the "logging" variable.
	# The string value is a description of the subnet and why it was included.
	const always_log: table[subnet] of string &redef;
}

event bro_init()
	{
	LOG::create_logs("http-ext", logging, split_log_file, T);
	LOG::define_header("http-ext", cat_sep("\t", "\\N",
	                                       "ts",
	                                       "orig_h", "orig_p",
	                                       "resp_h", "resp_p",
	                                       "force_log_reasons",
	                                       "method", "url", "referrer",
	                                       "user_agent", "proxied_for",
	                                       "mime_type", "md5",
	                                       "status_code", "status_msg"));
	
	# Set this log to always accept output (All) because the POST logging
	# must be specifically enabled per-request anyway.
	LOG::create_logs("http-client-body", All, split_log_file, T);
	LOG::define_header("http-client-body", cat_sep("\t", "\\N",
	                                               "ts",
	                                               "orig_h", "orig_p",
	                                               "resp_h", "resp_p",
	                                               "force_log_reasons", "method",
	                                               "url", "user_agent", 
	                                               "referrer", "client_body"));
	
	LOG::create_logs("http-user-agents", track_user_agents_for, split_log_file, T);
	LOG::define_header("http-user-agents", cat_sep("\t", "\\N",
	                                               "host", "user_agent"));
	
	}

event http_ext(id: conn_id, si: http_ext_session_info) &priority=-9
	{
	if ( id$resp_h in always_log )
		{
		si$force_log = T;
		add si$force_log_reasons[fmt("server_in_logged_subnet_%s", always_log[id$resp_h])];
		}
		
	if ( id$orig_h in always_log )
		{
		si$force_log = T;
		add si$force_log_reasons[fmt("client_in_logged_subnet_%s", always_log[id$orig_h])];
		}

	local log_line = cat_sep("\t", "\\N",
	                         si$start_time,
	                         id$orig_h, port_to_count(id$orig_p),
	                         id$resp_h, port_to_count(id$resp_p),
	                         fmt_str_set(si$force_log_reasons, /DONTMATCH/),
	                         si$method, si$url, si$referrer,
	                         si$user_agent, si$proxied_for,
	                         si$mime_type, si$md5,
	                         si$status_code, si$status_msg);
	LOG::print_log_by_id("http-ext", id, si$force_log, si$tags, log_line);
	}

# Do the user-agent logging.
event http_ext(id: conn_id, si: http_ext_session_info)
	{
	if ( si$new_user_agent )
		{
		local log = LOG::get_file_by_addr("http-user-agents", id$orig_h, T);
		print log, cat_sep("\t", "\\N", id$orig_h, si$user_agent);
		}
	}

# This is for logging POST contents during suspicious POSTs.
event http_entity_data(c: connection, is_orig: bool, length: count, data: string)
	{
	if ( !is_orig || c$id !in HTTP::conn_info ) return;
	
	local si = HTTP::conn_info[c$id];
	
	# This shouldn't really be done in the logging script, but it avoids
	# needing to handle the http_entity_data event twice.
	if ( suspicious_http_posts in data )
		{
		si$force_log_client_body = T;
		add si$force_log_reasons["suspicious_client_body"];
		}

	if ( si$force_log_client_body )
		{
		local log = LOG::get_file_by_id("http-client-body", c$id, T);
		print log, cat_sep("\t", "\\N",
		                   si$start_time,
		                   c$id$orig_h, port_to_count(c$id$orig_p),
		                   c$id$resp_h, port_to_count(c$id$resp_p),
		                   fmt_str_set(si$force_log_reasons, /DONTMATCH/),
		                   si$method,
		                   si$url,
		                   si$user_agent,
		                   si$referrer,
		                   data);
		
		# Stop logging the client body.  The log file fills up like crazy 
		# in some cases if we don't stop this.  If another chunk of data
		# is detected as loggable later, it will be reenabled anyway.
		si$force_log_client_body=F;
		}
	}
