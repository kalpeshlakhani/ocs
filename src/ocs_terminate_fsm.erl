%%% ocs_terminate_fsm.erl
%%% vim: ts=3
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @copyright 2016 - 2020 SigScale Global Inc.
%%% @end
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc This {@link //stdlib/gen_fsm. gen_fsm} behaviour callback module
%%% 	implements procedures for session termination initiated by non-3GPP
%%% 	access network.
%%%
%%% @reference <a href="https://webapp.etsi.org/key/key.asp?GSMSpecPart1=29&amp;GSMSpecPart2=273">
%%% 	3GPP TS 29.273 - 3GPP EPS AAA interfaces</a>
%%%
-module(ocs_terminate_fsm).
-copyright('Copyright (c) 2016 - 2020 SigScale Global Inc.').

-behaviour(gen_fsm).

%% export the ocs_terminate_fsm API
-export([]).

%% export the ocs_terminate_fsm state callbacks
-export([idle/2, deregister/2]).

%% export the call backs needed for gen_fsm behaviour
-export([init/1, handle_event/3, handle_sync_event/4, handle_info/3,
			terminate/3, code_change/4]).

-include("ocs.hrl").
-include("diameter_gen_3gpp.hrl").
-include("diameter_3gpp.hrl").
-include("diameter_gen_3gpp_sta_application.hrl").
-include("diameter_gen_3gpp_swm_application.hrl").
-include("diameter_gen_3gpp_s6b_application.hrl").
-include("diameter_gen_3gpp_swx_application.hrl").
-include_lib("diameter/include/diameter.hrl").
-include_lib("diameter/include/diameter_gen_base_rfc6733.hrl").

-define(IANA_PEN_3GPP, 10415).
-define(STa_APPLICATION_ID, 16777250).
-define(SWm_APPLICATION_ID, 16777264).
-define(S6b_APPLICATION_ID,  16777272).
-define(SWx_APPLICATION_ID, 16777265).
-define(STa_APPLICATION, ocs_diameter_3gpp_sta_application).
-define(SWm_APPLICATION, ocs_diameter_3gpp_swm_application).
-define(S6b_APPLICATION, ocs_diameter_3gpp_s6b_application).
-define(SWx_APPLICATION, ocs_diameter_3gpp_swx_application).
-define(TIMEOUT, 5000).

-record(statedata,
		{identity :: binary() | undefined,
		origin_host :: binary(),
		origin_realm :: binary(),
		server_address :: inet:ip_address(),
		server_port :: pos_integer(),
		client_address :: inet:ip_address(),
		client_port :: pos_integer(),
		service :: tuple() | undefined,
		hss_realm :: string() | undefined,
		hss_host :: string() | undefined,
		nas_host :: string() | undefined,
		nas_realm :: string() | undefined,
		nas_address :: inet:ip_address() | undefined,
		request :: #'3gpp_sta_STR'{} | #'3gpp_swm_STR'{} | #'3gpp_s6b_STR'{},
		session_id :: string()}).
-type statedata() :: #statedata{}.

%% support deprecated_time_unit()
-define(MILLISECOND, milli_seconds).
%-define(MILLISECOND, millisecond).

%%----------------------------------------------------------------------
%%  The ocs_terminate_fsm API
%%----------------------------------------------------------------------

%%----------------------------------------------------------------------
%%  The ocs_terminate_fsm gen_fsm call backs
%%----------------------------------------------------------------------

-spec init(Args) -> Result
	when
		Args :: list(),
		Result :: {ok, StateName, StateData}
		| {ok, StateName, StateData, Timeout}
		| {ok, StateName, StateData, hibernate}
		| {stop, Reason} | ignore,
		StateName :: atom(),
		StateData :: statedata(),
		Timeout :: non_neg_integer() | infinity,
		Reason :: term().
%% @doc Initialize the {@module} finite state machine.
%% @see //stdlib/gen_fsm:init/1
%% @private
%%
init([diameter, ServerAddress, ServerPort, ClientAddress, ClientPort,
		_PasswordReq, _Trusted, SessionId, _ApplicationId, _AuthReqType,
		OriginHost, OriginRealm, DestinationHost, DestinationRealm,
		Request, _Options] = _Args) ->
	Service = {ocs_diameter_auth, ServerAddress, ServerPort},
	process_flag(trap_exit, true),
	{ok, idle, #statedata{service = Service,
			server_address = ServerAddress, server_port = ServerPort,
			client_address = ClientAddress, client_port = ClientPort,
			session_id = SessionId, request = Request,
			origin_host = OriginHost, origin_realm = OriginRealm,
			nas_host = DestinationHost, nas_realm = DestinationRealm}, 0}.

-spec idle(Event, StateData) -> Result
	when
		Event :: timeout | term(),
		StateData :: statedata(),
		Result :: {next_state, NextStateName, NewStateData}
				| {next_state, NextStateName, NewStateData, Timeout}
				| {next_state, NextStateName, NewStateData, hibernate}
				| {stop, Reason, NewStateData},
		NextStateName :: atom(),
		NewStateData :: statedata(),
		Timeout :: non_neg_integer() | infinity,
		Reason :: normal | term().
%% @doc Handle events sent with {@link //stdlib/gen_fsm:send_event/2.
%%		gen_fsm:send_event/2} in the <b>idle</b> state.
%% @@see //stdlib/gen_fsm:StateName/2
%% @private
%%
idle(timeout, #statedata{request = Request,
			session_id = SessionId} = StateData)
		when is_record(Request, '3gpp_sta_STR');
		is_record(Request, '3gpp_swm_STR'),
		is_record(Request, '3gpp_s6b_STR') ->
	Identity = case Request of
		#'3gpp_sta_STR'{'User-Name' = [UserName]} ->
			UserName;
		#'3gpp_swm_STR'{'User-Name' = [UserName]} ->
			UserName;
		#'3gpp_s6b_STR'{'User-Name' = [UserName]} ->
			UserName
	end,
	NewStateData = StateData#statedata{identity = Identity},
	F = fun() ->
			case mnesia:read(session, SessionId, write) of
				[#session{imsi = Identity, hss_realm = undefined}] ->
					mnesia:delete(session, SessionId, write);
				[#session{imsi = Identity, hss_realm = HR, hss_host = HH}] ->
					{HR, HH};
				[] ->
					not_found
			end
	end,
	case mnesia:transaction(F) of
		{atomic, ok} ->
			send_diameter_response(?'DIAMETER_BASE_RESULT-CODE_SUCCESS', NewStateData),
			{stop, {shutdown, SessionId}, NewStateData};
		{atomic, {HssRealm, HssHost}} ->
			NextStateData = StateData#statedata{hss_realm = HssRealm, hss_host = HssHost},
			send_diameter_deregister(NextStateData),
			{next_state, deregister, NextStateData, ?TIMEOUT};
		{atomic, not_found} ->
			send_diameter_response(?'DIAMETER_BASE_RESULT-CODE_UNKNOWN_SESSION_ID', NewStateData),
			{stop, {shutdown, SessionId}, NewStateData};
		{aborted, Reason} ->
			send_diameter_response(?'DIAMETER_BASE_RESULT-CODE_UNABLE_TO_COMPLY', NewStateData),
			{stop, Reason, NewStateData}
	end.

-spec deregister(Event, StateData) -> Result
	when
		Event :: timeout | term(),
		StateData :: statedata(),
		Result :: {next_state, NextStateName, NewStateData}
				| {next_state, NextStateName, NewStateData, Timeout}
				| {next_state, NextStateName, NewStateData, hibernate}
				| {stop, Reason, NewStateData},
		NextStateName :: atom(),
		NewStateData :: statedata(),
		Timeout :: non_neg_integer() | infinity,
		Reason :: normal | term().
%% @doc Handle events sent with {@link //stdlib/gen_fsm:send_event/2.
%%		gen_fsm:send_event/2} in the <b>deregister</b> state.
%% @@see //stdlib/gen_fsm:StateName/2
%% @private
%%
deregister(#'3gpp_swx_SAA'{'Result-Code'
		= [?'DIAMETER_BASE_RESULT-CODE_SUCCESS']} = _Answer, StateData) ->
	send_diameter_response(?'DIAMETER_BASE_RESULT-CODE_SUCCESS', StateData),
	deregister1(StateData);
deregister(#'3gpp_swx_SAA'{'Experimental-Result'
		= [?'DIAMETER_ERROR_IDENTITY_NOT_REGISTERED']} = _Answer,
		#statedata{session_id = SessionId, identity = Identity,
		hss_realm = HssRealm, hss_host = HssHost} = StateData) ->
	error_logger:error_report(["Identity not registered",
			{imsi, Identity}, {hss_realm, HssRealm},
			{hss_host, HssHost}, {session, SessionId}]),
	send_diameter_response(?'DIAMETER_BASE_RESULT-CODE_SUCCESS', StateData),
	deregister1(StateData);
deregister(#'3gpp_swx_SAA'{'Result-Code' = [ResultCode]} = _Answer,
		#statedata{session_id = SessionId, identity = Identity,
		hss_realm = HssRealm, hss_host = HssHost} = StateData) ->
	error_logger:error_report(["Unexpected deregistration result",
			{imsi, Identity}, {hss_realm, HssRealm},
			{hss_host, HssHost}, {session, SessionId},
			{result, ResultCode}]),
	send_diameter_response(?'DIAMETER_BASE_RESULT-CODE_UNABLE_TO_COMPLY', StateData),
	{stop, {shutdown, SessionId}, StateData};
deregister(#'3gpp_swx_SAA'{'Experimental-Result' = [ResultCode]} = _Answer,
		#statedata{session_id = SessionId, identity = Identity,
		hss_realm = HssRealm, hss_host = HssHost} = StateData) ->
	error_logger:error_report(["Unexpected deregistration result",
			{imsi, Identity}, {hss_realm, HssRealm},
			{hss_host, HssHost}, {session, SessionId},
			{result, ResultCode}]),
	send_diameter_response(?'DIAMETER_BASE_RESULT-CODE_UNABLE_TO_COMPLY', StateData),
	{stop, {shutdown, SessionId}, StateData}.
%% @hidden
deregister1(#statedata{session_id = SessionId} = StateData) ->
	F = fun() -> mnesia:delete(session, SessionId, write) end,
	case mnesia:transaction(F) of
		{atomic, ok} ->
			{stop, {shutdown, SessionId}, StateData};
		{aborted, Reason} ->
			{stop, Reason, StateData}
	end.

-spec handle_event(Event, StateName, StateData) -> Result
	when
		Event :: term(),
		StateName :: atom(),
      StateData :: statedata(),
		Result :: {next_state, NextStateName, NewStateData}
				| {next_state, NextStateName, NewStateData, Timeout}
				| {next_state, NextStateName, NewStateData, hibernate}
				| {stop, Reason, NewStateData},
		NextStateName :: atom(),
		NewStateData :: statedata(),
		Timeout :: non_neg_integer() | infinity,
		Reason :: normal | term().
%% @doc Handle an event sent with
%% 	{@link //stdlib/gen_fsm:send_all_state_event/2.
%% 	gen_fsm:send_all_state_event/2}.
%% @see //stdlib/gen_fsm:handle_event/3
%% @private
%%
handle_event(Event, _StateName, StateData) ->
	{stop, Event, StateData}.

-spec handle_sync_event(Event, From, StateName, StateData) -> Result
	when
		Event :: term(),
		From :: {Pid, Tag},
		Pid :: pid(),
		Tag :: term(),
      StateName :: atom(),
		StateData :: statedata(),
		Result :: {reply, Reply, NextStateName, NewStateData}
			| {reply, Reply, NextStateName, NewStateData, Timeout}
			| {reply, Reply, NextStateName, NewStateData, hibernate}
			| {next_state, NextStateName, NewStateData}
			| {next_state, NextStateName, NewStateData, Timeout}
			| {next_state, NextStateName, NewStateData, hibernate}
			| {stop, Reason, Reply, NewStateData}
			| {stop, Reason, NewStateData},
		Reply :: term(),
		NextStateName ::atom(),
		NewStateData :: statedata(),
		Timeout :: non_neg_integer() | infinity,
		Reason :: normal | term().
%% @doc Handle an event sent with
%% 	{@link //stdlib/gen_fsm:sync_send_all_state_event/2.
%% 	gen_fsm:sync_send_all_state_event/2,3}.
%% @see //stdlib/gen_fsm:handle_sync_event/4
%% @private
%%
handle_sync_event(Event, _From, _StateName, StateData) ->
	{stop, Event, StateData}.

-spec handle_info(Info, StateName, StateData) -> Result
	when
		Info :: term(),
		StateName :: atom(),
		StateData :: statedata(),
		Result :: {next_state, NextStateName, NewStateData}
				| {next_state, NextStateName, NewStateData, Timeout}
		| {next_state, NextStateName, NewStateData, hibernate}
		| {stop, Reason, NewStateData},
		NextStateName :: atom(),
		NewStateData :: statedata(),
		Timeout :: non_neg_integer() | infinity,
		Reason :: normal | term().
%% @doc Handle a received message.
%% @see //stdlib/gen_fsm:handle_info/3
%% @private
%%
handle_info(Info, request, StateData) ->
	{stop, Info, StateData}.

-spec terminate(Reason, StateName, StateData) -> any()
	when
		Reason :: normal | shutdown | term(),
		StateName :: atom(),
      StateData :: statedata().
%% @doc Cleanup and exit.
%% @see //stdlib/gen_fsm:terminate/3
%% @private
%%
terminate(_Reason, _StateName, _StateData) ->
	ok.

-spec code_change(OldVsn, StateName, StateData, Extra ) -> Result
	when
		OldVsn :: (Vsn | {down, Vsn}),
		Vsn :: term(),
      StateName :: atom(),
		StateData :: statedata(),
		Extra :: term(),
		Result :: {ok, NextStateName, NewStateData},
		NextStateName :: atom(),
		NewStateData :: statedata().
%% @doc Update internal state data during a release upgrade&#047;downgrade.
%% @see //stdlib/gen_fsm:code_change/4
%% @private
%%
code_change(_OldVsn, StateName, StateData, _Extra) ->
	{ok, StateName, StateData}.

%%----------------------------------------------------------------------
%%  internal functions
%%----------------------------------------------------------------------

-spec send_diameter_response(ResultCode, StateData) -> ok
	when
		ResultCode :: pos_integer(),
		StateData :: #statedata{}.
%% @doc Send DIAMETER response.
%% @hidden
send_diameter_response(ResultCode,
		#statedata{request = #'3gpp_sta_STR'{} = Request,
		session_id = SessionId, service = Service,
		server_address = ServerAddress, server_port = ServerPort,
		client_address = ClientAddress, client_port = ClientPort,
		origin_host = OriginHost, origin_realm = OriginRealm} = _StateData)
		when is_integer(ResultCode), is_binary(OriginHost),
		is_binary(OriginRealm)->
	Server = {ServerAddress, ServerPort},
	Client = {ClientAddress, ClientPort},
	Answer = #'3gpp_sta_STA'{'Session-Id' = SessionId,
			'Result-Code' = ResultCode,
			'Origin-Host' = OriginHost,
			'Origin-Realm' = OriginRealm},
	ok = ocs_log:auth_log(diameter, Server, Client, Request, Answer),
	gen_server:cast(Service, {self(), Answer});
send_diameter_response(ResultCode,
		#statedata{request = #'3gpp_swm_STR'{} = Request,
		session_id = SessionId, service = Service,
		server_address = ServerAddress, server_port = ServerPort,
		client_address = ClientAddress, client_port = ClientPort,
		origin_host = OriginHost, origin_realm = OriginRealm} = _StateData)
		when is_integer(ResultCode), is_binary(OriginHost),
		is_binary(OriginRealm) ->
	Server = {ServerAddress, ServerPort},
	Client = {ClientAddress, ClientPort},
	Answer = #'3gpp_swm_STA'{'Session-Id' = SessionId,
			'Result-Code' = ResultCode,
			'Origin-Host' = OriginHost,
			'Origin-Realm' = OriginRealm},
	ok = ocs_log:auth_log(diameter, Server, Client, Request, Answer),
	gen_server:cast(Service, {self(), Answer});
send_diameter_response(ResultCode,
		#statedata{request = #'3gpp_s6b_STR'{} = Request,
		session_id = SessionId, service = Service,
		server_address = ServerAddress, server_port = ServerPort,
		client_address = ClientAddress, client_port = ClientPort,
		origin_host = OriginHost, origin_realm = OriginRealm} = _StateData)
		when is_integer(ResultCode), is_binary(OriginHost),
		is_binary(OriginRealm) ->
	Server = {ServerAddress, ServerPort},
	Client = {ClientAddress, ClientPort},
	Answer = #'3gpp_swm_STA'{'Session-Id' = SessionId,
			'Result-Code' = ResultCode,
			'Origin-Host' = OriginHost,
			'Origin-Realm' = OriginRealm},
	ok = ocs_log:auth_log(diameter, Server, Client, Request, Answer),
	gen_server:cast(Service, {self(), Answer}).

-spec send_diameter_deregister(StateData) -> Result
	when
		StateData :: #statedata{},
		Result :: ok | {error, Reason},
		Reason :: term().
%% @doc Send DIAMETER Server-Assignment-Request (SAR) deregistration. 
%% @hidden
send_diameter_deregister(#statedata{identity = Identity,
		origin_host = OriginHost, origin_realm = OriginRealm,
		nas_host = NasHost, nas_realm = NasRealm,
		service = Service} = _StateData) ->
	SessionId = diameter:session_id([OriginHost]),
	Request = #'3gpp_swx_SAR'{'Session-Id' = SessionId,
			'User-Name' = [Identity], 'Origin-Realm' = OriginRealm,
			'Origin-Host' = OriginHost, 'Destination-Realm' = NasRealm,
			'Destination-Host' = NasHost,
			'Server-Assignment-Type' = ?'3GPP_SWX_SERVER-ASSIGNMENT-TYPE_USER_DEREGISTRATION'},
	diameter:call(Service, ?SWx_APPLICATION,
			Request, [detach, {extra, [self()]}]).

