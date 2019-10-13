%%% ocs_eap_aka_fsm.erl
%%% vim: ts=3
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @copyright 2016 - 2018 SigScale Global Inc.
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
%%% 	implements the functions associated with an EAP server within EAP
%%% 	3rd Generation Authentication and Key Agreement (EAP-AKA')
%%% 	in the {@link //ocs. ocs} application.
%%%
%%% @reference <a href="http://tools.ietf.org/html/rfc4187">
%%% 	RFC4187 - Extensible Authentication Protocol Method for 3rd Generation
%%% 		Authentication and Key Agreement (EAP-AKA)</a>
%%% @reference <a href="http://tools.ietf.org/html/rfc5448">
%%% 	RFC5448 - Improved Extensible Authentication Protocol Method for
%%% 		3rd Generation Authentication and Key Agreement (EAP-AKA')</a>
%%% @reference <a href="https://webapp.etsi.org/key/key.asp?GSMSpecPart1=33&amp;GSMSpecPart2=402&amp;Search=search">
%%% 	3GPP TS 33.402 - Security aspects of non-3GPP accesses</a>
%%% @reference <a href="https://webapp.etsi.org/key/key.asp?GSMSpecPart1=23&amp;GSMSpecPart2=003&amp;Search=search">
%%% 	3GPP TS 23.003 - Numbering, addressing and identification</a>
%%%
-module(ocs_eap_aka_fsm).
-copyright('Copyright (c) 2016 - 2018 SigScale Global Inc.').

-behaviour(gen_fsm).

%% export the ocs_eap_aka_fsm API
-export([]).

%% export the ocs_eap_aka_fsm state callbacks
-export([eap_start/2, identity/2, vector/2, challenge/2, failure/2]).

%% export the call backs needed for gen_fsm behaviour
-export([init/1, handle_event/3, handle_sync_event/4, handle_info/3,
			terminate/3, code_change/4]).

-include_lib("radius/include/radius.hrl").
-include_lib("diameter/include/diameter_gen_base_rfc6733.hrl").
-include("diameter_gen_eap_application_rfc4072.hrl").
-include("diameter_gen_nas_application_rfc7155.hrl").
-include("ocs_eap_codec.hrl").

-record(statedata,
		{sup :: pid(),
		server_address :: inet:ip_address(),
		server_port :: pos_integer(),
		client_address :: undefined | inet:ip_address(),
		client_port :: undefined | pos_integer(),
		radius_fsm :: undefined | pid(),
		auc_fsm :: undefined | pid(),
		session_id:: string() | {NAS :: inet:ip_address() | string(),
				Port :: string(), Peer :: string()},
		request :: undefined | #diameter_eap_app_DER{} | #radius{},
		secret :: undefined | binary(),
		eap_id = 0 :: byte(),
		server_id  ::  binary(),
		auth_app_id :: undefined | integer(),
		auth_req_type :: undefined | integer(),
		origin_host :: undefined | binary(),
		origin_realm :: undefined | binary(),
		diameter_port_server :: undefined | pid(),
		password_required :: boolean(),
		trusted :: boolean(),
		service_type :: undefined | integer(),
		keys :: [{pos_integer(), binary()}],
		id_req :: any | full | permanent | undefined,
		identity :: binary() | undefined,
		res :: binary() | undefined,
		ck :: binary() | undefined,
		ik :: binary() | undefined,
		msk :: binary() | undefined,
		emsk :: binary() | undefined,
		kaut :: binary() | undefined,
		kencr :: binary() | undefined,
		kre :: binary() | undefined}).
-type statedata() :: #statedata{}.

-define(TIMEOUT, 30000).

-define(EAP_APPLICATION_ID, 5).

%% 3GPP TS 23.003 14.5 Temporary identities
-define(PERM_TAG, $6).
-define(TEMP_TAG, $2).
-define(FAST_TAG, $4).

%%----------------------------------------------------------------------
%%  The ocs_eap_aka_fsm API
%%----------------------------------------------------------------------

%%----------------------------------------------------------------------
%%  The ocs_eap_aka_fsm gen_fsm call backs
%%----------------------------------------------------------------------

init([Sup, diameter, ServerAddress, ServerPort, ClientAddress, ClientPort,
		PasswordReq, Trusted, SessionId, ApplicationId, AuthReqType, OHost, ORealm,
		_DHost, _DRealm, Request, _Options] = _Args) ->
	{ok, Hostname} = inet:gethostname(),
	{ok, Keys} = application:get_env(aka_kpseu),
	case global:whereis_name({ocs_diameter_auth, ServerAddress, ServerPort}) of
		undefined ->
			{stop, ocs_diameter_auth_port_server_not_found};
		PortServer ->
			ServiceType = case Request of
				#diameter_nas_app_AAR{'Service-Type' = [ST]} ->
					ST;
				_ ->
					undefined
			end,
			StateData = #statedata{sup = Sup,
					server_address = ServerAddress,
					server_port = ServerPort, client_address = ClientAddress,
					client_port = ClientPort, session_id = SessionId,
					server_id = list_to_binary(Hostname), auth_app_id = ApplicationId,
					auth_req_type = AuthReqType, origin_host = OHost,
					origin_realm = ORealm, diameter_port_server = PortServer,
					request = Request, password_required = PasswordReq,
					trusted = Trusted, keys = Keys, service_type = ServiceType},
			process_flag(trap_exit, true),
			{ok, eap_start, StateData, 0}
		end;
init([Sup, radius, ServerAddress, ServerPort, ClientAddress, ClientPort,
		RadiusFsm, Secret, PasswordReq, Trusted, SessionID,
		#radius{attributes = Attributes} = AccessRequest] = _Args) ->
	{ok, Hostname} = inet:gethostname(),
	{ok, Keys} = application:get_env(aka_kpseu),
	ServiceType = case radius_attributes:find(?ServiceType, Attributes) of
		{error, not_found} ->
			undefined;
		{_, ST} ->
			ST
	end,
	StateData = #statedata{sup = Sup,
			server_address = ServerAddress,
			server_port = ServerPort, client_address = ClientAddress,
			client_port = ClientPort, radius_fsm = RadiusFsm,
			secret = Secret, session_id = SessionID,
			server_id = list_to_binary(Hostname), request = AccessRequest,
			password_required = PasswordReq, trusted = Trusted,
			keys = Keys, service_type = ServiceType},
	process_flag(trap_exit, true),
	{ok, eap_start, StateData, 0}.

-spec eap_start(Event, StateData) -> Result
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
%%		gen_fsm:send_event/2} in the <b>eap_start</b> state.
%% @@see //stdlib/gen_fsm:StateName/2
%% @private
eap_start(timeout, #statedata{eap_id = EapID,
		session_id = SessionId, auth_req_type = AuthReqType,
		request = #diameter_eap_app_DER{'EAP-Payload' = []} = Request,
		origin_host = OHost, origin_realm = ORealm,
		diameter_port_server = PortServer, sup = Sup} = StateData) ->
	Children = supervisor:which_children(Sup),
	{_, AucFsm, _, _} = lists:keyfind(ocs_eap_aka_auc_fsm, 1, Children),
	EapData = ocs_eap_codec:eap_aka(#eap_aka_identity{fullauth_id_req = true}),
	NewStateData = StateData#statedata{request = undefined,
			auc_fsm = AucFsm, id_req = full},
	EapPacket = #eap_packet{code = request,
			type = ?AKAprime, identifier = EapID, data = EapData},
	send_diameter_response(SessionId, AuthReqType,
			?'DIAMETER_BASE_RESULT-CODE_MULTI_ROUND_AUTH', OHost, ORealm,
			EapPacket, PortServer, Request, StateData),
	{next_state, identity, NewStateData, ?TIMEOUT};
eap_start(timeout, #statedata{sup = Sup, eap_id = EapID,
		session_id = SessionId, auth_req_type = AuthReqType,
		request = #diameter_eap_app_DER{'EAP-Payload' = EapMessage} = Request,
		origin_host = OHost, origin_realm = ORealm,
		diameter_port_server = PortServer,
		trusted = Trusted, keys = Keys} = StateData) ->
	Children = supervisor:which_children(Sup),
	{_, AucFsm, _, _} = lists:keyfind(ocs_eap_aka_auc_fsm, 1, Children),
	NewStateData = StateData#statedata{auc_fsm = AucFsm},
	try
		case ocs_eap_codec:eap_packet(EapMessage) of
			#eap_packet{code = response, type = ?Identity,
					identifier = StartEapID,
					data = <<?PERM_TAG, PermanentID/binary>> = Identity}
					when Trusted == true ->
				NextStateData = NewStateData#statedata{eap_id = StartEapID,
						identity = Identity},
				[IMSI | _] = binary:split(PermanentID, <<$@>>, []),
				% @todo handle DIAMETER ANID AVP
				gen_fsm:send_event(AucFsm, {self(), IMSI, "WLAN"}),
				{next_state, vector, NextStateData, ?TIMEOUT};
			#eap_packet{code = response, type = ?Identity,
					identifier = StartEapID,
					data = <<?TEMP_TAG:6, _/bits>> = Identity}
					when Trusted == true ->
				NextStateData = NewStateData#statedata{eap_id = StartEapID,
						identity = Identity},
				[Pseudonym | _] = binary:split(Identity, <<$@>>, []),
				CompressedIMSI = decrypt_imsi(Pseudonym, Keys),
				IMSI = compressed_imsi(CompressedIMSI),
				% @todo handle DIAMETER ANID AVP
				gen_fsm:send_event(AucFsm, {self(), IMSI, "WLAN"}),
				{next_state, vector, NextStateData, ?TIMEOUT};
			#eap_packet{code = response, type = ?Identity,
					identifier = StartEapID,
					data = <<?FAST_TAG:6, _/bits>> = Identity}
					when Trusted == true ->
				% @todo handle fast re-authentication
				NextEapID = (StartEapID rem 255) + 1,
				EapData = ocs_eap_codec:eap_aka(#eap_aka_identity{fullauth_id_req = true}),
				NextStateData = NewStateData#statedata{request = undefined,
						eap_id = NextEapID, id_req = full, identity = Identity},
				EapPacket = #eap_packet{code = request,
						type = ?AKAprime, identifier = NextEapID, data = EapData},
				send_diameter_response(SessionId, AuthReqType,
						?'DIAMETER_BASE_RESULT-CODE_MULTI_ROUND_AUTH', OHost, ORealm,
						EapPacket, PortServer, Request, NextStateData),
				{next_state, identity, NextStateData, ?TIMEOUT};
			#eap_packet{code = response, type = ?Identity,
					identifier = StartEapID, data = Identity} when Trusted == false ->
				NextEapID = (StartEapID rem 255) + 1,
				EapData = ocs_eap_codec:eap_aka(#eap_aka_identity{fullauth_id_req = true}),
				NextStateData = NewStateData#statedata{request = undefined,
						eap_id = NextEapID, identity = Identity, id_req = full},
				EapPacket = #eap_packet{code = request,
						type = ?AKAprime, identifier = NextEapID, data = EapData},
				send_diameter_response(SessionId, AuthReqType,
						?'DIAMETER_BASE_RESULT-CODE_MULTI_ROUND_AUTH', OHost, ORealm,
						EapPacket, PortServer, Request, NextStateData),
				{next_state, identity, NextStateData, ?TIMEOUT};
			#eap_packet{code = request, identifier = NewEapID} ->
				EapPacket = #eap_packet{code = response, type = ?LegacyNak,
						identifier = NewEapID, data = <<0>>},
				send_diameter_response(SessionId, AuthReqType,
						?'DIAMETER_BASE_RESULT-CODE_UNABLE_TO_COMPLY', OHost, ORealm,
						EapPacket, PortServer, Request, NewStateData),
				{stop, {shutdown, SessionId}, NewStateData};
			#eap_packet{code = Code, type = EapType,
					identifier = NewEapID, data = Data} ->
				error_logger:warning_report(["Unknown EAP received",
						{pid, self()}, {session_id, SessionId}, {code, Code},
						{type, EapType}, {identifier, NewEapID}, {data, Data}]),
				EapPacket = #eap_packet{code = failure, identifier = NewEapID},
				send_diameter_response(SessionId, AuthReqType,
						?'DIAMETER_BASE_RESULT-CODE_UNABLE_TO_COMPLY', OHost, ORealm,
					EapPacket, PortServer, Request, NewStateData),
				{stop, {shutdown, SessionId}, NewStateData}
		end
	catch
		{'EXIT', _Reason} ->
			EapPacket1 = #eap_packet{code = failure, identifier = EapID},
			send_diameter_response(SessionId, AuthReqType,
					?'DIAMETER_BASE_RESULT-CODE_UNABLE_TO_COMPLY', OHost, ORealm,
					EapPacket1, PortServer, Request, NewStateData),
			{stop, {shutdown, SessionId}, NewStateData}
	end;
%% @hidden
eap_start(timeout, #statedata{sup = Sup, eap_id = EapID,
		request = #radius{code = ?AccessRequest, id = RadiusID,
		authenticator = RequestAuthenticator,
		attributes = RequestAttributes}, session_id = SessionID,
		trusted = Trusted, keys = Keys} = StateData) ->
	Children = supervisor:which_children(Sup),
	{_, AucFsm, _, _} = lists:keyfind(ocs_eap_aka_auc_fsm, 1, Children),
	NewStateData = StateData#statedata{auc_fsm = AucFsm},
	case radius_attributes:find(?EAPMessage, RequestAttributes) of
		{ok, <<>>} ->
			EapData = ocs_eap_codec:eap_aka(#eap_aka_identity{fullauth_id_req = true}),
			NextStateData = NewStateData#statedata{request = undefined, id_req = full},
			EapPacket = #eap_packet{code = request,
					type = ?AKAprime, identifier = EapID, data = EapData},
			send_radius_response(EapPacket, ?AccessChallenge, [], RadiusID,
					RequestAuthenticator, RequestAttributes, NewStateData),
			{next_state, identity, NextStateData, ?TIMEOUT};
		{ok, EAPMessage} ->
			try
				case ocs_eap_codec:eap_packet(EAPMessage) of
					#eap_packet{code = response, type = ?Identity,
							identifier = StartEapID,
							data = <<?PERM_TAG, PermanentID/binary>> = Identity}
							when Trusted == true ->
						NextStateData = NewStateData#statedata{eap_id = StartEapID,
								identity = Identity},
						[IMSI | _] = binary:split(PermanentID, <<$@>>, []),
						% @todo handle RADIUS attribute for ANID
						gen_fsm:send_event(AucFsm, {self(), IMSI, "WLAN"}),
						{next_state, vector, NextStateData, ?TIMEOUT};
					#eap_packet{code = response, type = ?Identity,
							identifier = StartEapID,
							data = <<?TEMP_TAG:6, _/bits>> = Identity}
							when Trusted == true ->
						NextStateData = NewStateData#statedata{eap_id = StartEapID,
								identity = Identity},
						[Pseudonym | _] = binary:split(Identity, <<$@>>, []),
						CompressedIMSI = decrypt_imsi(Pseudonym, Keys),
						IMSI = compressed_imsi(CompressedIMSI),
						% @todo handle RADIUS attribute for ANID
						gen_fsm:send_event(AucFsm, {self(), IMSI, "WLAN"}),
						{next_state, vector, NextStateData, ?TIMEOUT};
					#eap_packet{code = response, type = ?Identity,
							identifier = StartEapID,
							data = <<?FAST_TAG:6, _/bits>> = Identity}
							when Trusted == true ->
						% @todo handle fast re-authentication
						NextEapID = (StartEapID rem 255) + 1,
						EapData = ocs_eap_codec:eap_aka(#eap_aka_identity{fullauth_id_req = true}),
						NextStateData = NewStateData#statedata{request = undefined,
								eap_id = NextEapID, identity = Identity, id_req = full},
						EapPacket = #eap_packet{code = request,
								type = ?AKAprime, identifier = NextEapID, data = EapData},
						send_radius_response(EapPacket, ?AccessChallenge, [], RadiusID,
								RequestAuthenticator, RequestAttributes, NextStateData),
						{next_state, identity, NextStateData, ?TIMEOUT};
					#eap_packet{code = request, identifier = StartEapID} ->
						EapPacket = #eap_packet{code = response, type = ?LegacyNak,
								identifier = StartEapID, data = <<0>>},
						send_radius_response(EapPacket, ?AccessReject, [], RadiusID,
								RequestAuthenticator, RequestAttributes, NewStateData),
						{stop, {shutdown, SessionID}, StateData};
					#eap_packet{code = Code, type = EapType,
							identifier = StartEapID, data = Data} ->
						error_logger:warning_report(["Unknown EAP received",
								{pid, self()}, {session_id, SessionID}, {code, Code},
								{type, EapType}, {identifier, StartEapID}, {data, Data}]),
						EapPacket = #eap_packet{code = failure, identifier = StartEapID},
						send_radius_response(EapPacket, ?AccessReject, [], RadiusID,
								RequestAuthenticator, RequestAttributes, NewStateData),
						{stop, {shutdown, SessionID}, StateData}
				end
			catch
				{'EXIT', _Reason} ->
					EapPacket1 = #eap_packet{code = failure, identifier = EapID},
					send_radius_response(EapPacket1, ?AccessReject, [], RadiusID,
							RequestAuthenticator, RequestAttributes, NewStateData),
					{stop, {shutdown, SessionID}, StateData}
			end;
		{error, not_found} ->
			EapData = ocs_eap_codec:eap_aka(#eap_aka_identity{fullauth_id_req = true}),
			NextStateData = NewStateData#statedata{request = undefined, id_req = full},
			EapPacket = #eap_packet{code = request,
					type = ?AKAprime, identifier = EapID, data = EapData},
			send_radius_response(EapPacket, ?AccessChallenge, [], RadiusID,
					RequestAuthenticator, RequestAttributes, NewStateData),
			{next_state, identity, NextStateData, ?TIMEOUT}
	end.

-spec identity(Event, StateData) -> Result
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
%%		gen_fsm:send_event/2} in the <b>identity</b> state.
%% @@see //stdlib/gen_fsm:StateName/2
%% @private
identity(timeout, #statedata{session_id = SessionID} = StateData)->
	{stop, {shutdown, SessionID}, StateData};
identity(#diameter_eap_app_DER{'EAP-Payload' = EapMessage} = Request,
		#statedata{eap_id = EapID, session_id = SessionID,
		auth_req_type = AuthReqType, origin_host = OHost,
		origin_realm = ORealm, auc_fsm = AucFsm, id_req = IdReq,
		diameter_port_server = PortServer, keys = Keys} = StateData) ->
	try
		#eap_packet{code = response, type = ?AKAprime, identifier = EapID,
				data = Data} = ocs_eap_codec:eap_packet(EapMessage),
		case ocs_eap_codec:eap_aka(Data) of
			#eap_aka_identity{identity = <<?PERM_TAG,
					PermanentID/binary>> = Identity} when IdReq == full ->
				[IMSI | _] = binary:split(PermanentID, <<$@>>, []),
				% @todo handle DIAMETER ANID AVP
				gen_fsm:send_event(AucFsm, {self(), IMSI, "WLAN"}),
				NewStateData = StateData#statedata{request = Request,
						identity = Identity},
				{next_state, vector, NewStateData, ?TIMEOUT};
			#eap_aka_identity{identity = <<?TEMP_TAG:6, _/bits>> = Identity}
					when IdReq == full ->
				[Pseudonym | _] = binary:split(Identity, <<$@>>, []),
				CompressedIMSI = decrypt_imsi(Pseudonym, Keys),
				IMSI = compressed_imsi(CompressedIMSI),
				% @todo handle DIAMETER ANID AVP
				gen_fsm:send_event(AucFsm, {self(), IMSI, "WLAN"}),
				NewStateData = StateData#statedata{request = Request,
						identity = Identity},
				{next_state, vector, NewStateData, ?TIMEOUT}
		end
	catch
		_:_Reason ->
			EapPacket = #eap_packet{code = failure, identifier = EapID},
			send_diameter_response(SessionID, AuthReqType,
					?'DIAMETER_BASE_RESULT-CODE_INVALID_AVP_BITS', OHost, ORealm,
					EapPacket, PortServer, Request, StateData),
			{stop, {shutdown, SessionID}, StateData}
	end;
identity({#radius{id = RadiusID, authenticator = RequestAuthenticator,
		attributes = RequestAttributes} = Request, RadiusFsm},
		#statedata{eap_id = EapID, session_id = SessionID,
		auc_fsm = AucFsm, keys = Keys, id_req = IdReq} = StateData) ->
	NewStateData = StateData#statedata{request = Request,
			radius_fsm = RadiusFsm},
	try
		EapMessage = radius_attributes:fetch(?EAPMessage, RequestAttributes),
		#eap_packet{code = response, type = ?AKAprime, identifier = EapID,
				data = Data} = ocs_eap_codec:eap_packet(EapMessage),
		case ocs_eap_codec:eap_aka(Data) of
			#eap_aka_identity{identity = <<?PERM_TAG,
					PermanentID/binary>> = Identity} when IdReq == full ->
				[IMSI | _] = binary:split(PermanentID, <<$@>>, []),
				% @todo handle RADIUS attribute for ANID
				gen_fsm:send_event(AucFsm, {self(), IMSI, "WLAN"}),
				NextStateData = NewStateData#statedata{identity = Identity},
				{next_state, vector, NextStateData, ?TIMEOUT};
			#eap_aka_identity{identity = <<?TEMP_TAG:6, _/bits>> = Identity}
					when IdReq == full ->
				[Pseudonym | _] = binary:split(Identity, <<$@>>, []),
				CompressedIMSI = decrypt_imsi(Pseudonym, Keys),
				IMSI = compressed_imsi(CompressedIMSI),
				% @todo handle RADIUS attribute for ANID
				gen_fsm:send_event(AucFsm, {self(), IMSI, "WLAN"}),
				NextStateData = NewStateData#statedata{identity = Identity},
				{next_state, vector, NextStateData, ?TIMEOUT}
		end
	catch
		_:_Reason ->
			EapPacket = #eap_packet{code = failure, identifier = EapID},
			send_radius_response(EapPacket, ?AccessReject, [], RadiusID,
					RequestAuthenticator, RequestAttributes, NewStateData),
			{stop, {shutdown, SessionID}, NewStateData}
	end.

-spec vector(Event, StateData) -> Result
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
%%		gen_fsm:send_event/2} in the <b>vector</b> state.
%% @@see //stdlib/gen_fsm:StateName/2
%% @private
vector(timeout, #statedata{session_id = SessionID} = StateData)->
	{stop, {shutdown, SessionID}, StateData};
vector({RAND, AUTN, CKprime, IKprime, XRES}, #statedata{eap_id = EapID,
		request = #diameter_eap_app_DER{} = Request,
		auth_req_type = AuthReqType,
		origin_host = OHost, origin_realm = ORealm,
		diameter_port_server = PortServer,
		session_id = SessionID, identity = Identity} = StateData) ->
	NextEapID = (EapID rem 255) + 1,
	<<Kencr:16/binary, Kaut:32/binary, Kre:32/binary, MSK:64/binary,
			EMSK:64/binary, _/binary>> = prf(<<IKprime/binary,
			CKprime/binary>>, <<"EAP-AKA'", Identity/binary>>, 7),
	AkaChallenge1 = #eap_aka_challenge{mac = <<0:128>>,
			kdf = [1], network = <<"WLAN">>, rand = RAND, autn = AUTN},
	EapData1 = ocs_eap_codec:eap_aka(AkaChallenge1),
	EapPacket1 = #eap_packet{code = request, type = ?AKAprime,
			identifier = NextEapID, data = EapData1},
	EapMessage1 = ocs_eap_codec:eap_packet(EapPacket1),
	Mac = crypto:hmac(sha256, Kaut, EapMessage1, 16),
	AkaChallenge2 = AkaChallenge1#eap_aka_challenge{mac = Mac},
	EapData2 = ocs_eap_codec:eap_aka(AkaChallenge2),
	EapPacket2 = EapPacket1#eap_packet{data = EapData2},
	NewStateData = StateData#statedata{request = undefined,
			eap_id = NextEapID, res = XRES, ck = CKprime, ik = IKprime,
			msk = MSK, emsk = EMSK, kaut = Kaut, kencr = Kencr, kre = Kre},
	send_diameter_response(SessionID, AuthReqType,
			?'DIAMETER_BASE_RESULT-CODE_MULTI_ROUND_AUTH', OHost, ORealm,
			EapPacket2, PortServer, Request, NewStateData),
	{next_state, challenge, NewStateData};
vector({RAND, AUTN, CKprime, IKprime, XRES}, #statedata{eap_id = EapID,
		request = #radius{code = ?AccessRequest, id = RadiusID,
		authenticator = RequestAuthenticator, attributes = RequestAttributes},
		identity = Identity} = StateData) ->
	NextEapID = (EapID rem 255) + 1,
	<<Kencr:16/binary, Kaut:32/binary, Kre:32/binary, MSK:64/binary,
			EMSK:64/binary, _/binary>> = prf(<<IKprime/binary,
			CKprime/binary>>, <<"EAP-AKA'", Identity/binary>>, 7),
	AkaChallenge1 = #eap_aka_challenge{mac = <<0:128>>,
			kdf = [1], network = <<"WLAN">>, rand = RAND, autn = AUTN},
	EapData1 = ocs_eap_codec:eap_aka(AkaChallenge1),
	EapPacket1 = #eap_packet{code = request, type = ?AKAprime,
			identifier = NextEapID, data = EapData1},
	EapMessage1 = ocs_eap_codec:eap_packet(EapPacket1),
	Mac = crypto:hmac(sha256, Kaut, EapMessage1, 16),
	AkaChallenge2 = AkaChallenge1#eap_aka_challenge{mac = Mac},
	EapData2 = ocs_eap_codec:eap_aka(AkaChallenge2),
	EapPacket2 = EapPacket1#eap_packet{data = EapData2},
	NewStateData = StateData#statedata{request = undefined,
			eap_id = NextEapID, res = XRES, ck = CKprime, ik = IKprime,
			msk = MSK, emsk = EMSK, kaut = Kaut, kencr = Kencr, kre = Kre},
	send_radius_response(EapPacket2, ?AccessChallenge, [], RadiusID,
			RequestAuthenticator, RequestAttributes, NewStateData),
	{next_state, challenge, NewStateData}.

-spec challenge(Event, StateData) -> Result
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
%%		gen_fsm:send_event/2} in the <b>challenge</b> state.
%% @@see //stdlib/gen_fsm:StateName/2
%% @private
challenge(timeout, #statedata{session_id = SessionID} = StateData)->
	{stop, {shutdown, SessionID}, StateData};
challenge(#diameter_eap_app_DER{'EAP-Payload' = EapMessage} = Request,
		#statedata{eap_id = EapID, session_id = SessionID,
		auth_req_type = AuthReqType, origin_host = OHost,
		origin_realm = ORealm, diameter_port_server = PortServer,
		res = RES, kaut = Kaut} = StateData) ->
	try
		EapPacket = ocs_eap_codec:eap_packet(EapMessage),
		#eap_packet{code = response, type = ?AKAprime, identifier = EapID,
				data = Data} = EapPacket,
		case ocs_eap_codec:eap_aka(Data) of
			#eap_aka_challenge{res = RES, checkcode = <<>>, mac = MAC} = EAP ->
				Data1 = ocs_eap_codec:eap_aka(EAP#eap_aka_challenge{mac = <<0:128>>}),
				EapMessage1 = ocs_eap_codec:eap_packet(EapPacket#eap_packet{data = Data1}),
				case crypto:hmac(sha256, Kaut, EapMessage1, 16) of
					MAC ->
						EapPacket1 = #eap_packet{code = success, identifier = EapID},
						send_diameter_response(SessionID, AuthReqType,
								?'DIAMETER_BASE_RESULT-CODE_SUCCESS',
								OHost, ORealm, EapPacket1, PortServer, Request, StateData),
						{stop, {shutdown, SessionID}, StateData};
					_ ->
						EapPacket1 = #eap_packet{code = request,
								type = ?AKAprime, identifier = EapID,
								data = #eap_aka_notification{notification = 16384}},
						send_diameter_response(SessionID, AuthReqType,
								?'DIAMETER_BASE_RESULT-CODE_MULTI_ROUND_AUTH',
								OHost, ORealm, EapPacket1, PortServer, Request, StateData),
						{next_state, failure, StateData, ?TIMEOUT}
				end;
			#eap_aka_challenge{checkcode = <<>>} = _EAP ->
				EapPacket1 = #eap_packet{code = request,
						type = ?AKAprime, identifier = EapID,
						data = #eap_aka_notification{notification = 16384}},
				send_diameter_response(SessionID, AuthReqType,
						?'DIAMETER_BASE_RESULT-CODE_MULTI_ROUND_AUTH',
						OHost, ORealm, EapPacket1, PortServer, Request, StateData),
				{next_state, failure, StateData, ?TIMEOUT};
			% #eap_aka_synchronization_failure{auts = _AUTS} = _EAP ->
			% @todo handle resynchronization
			#eap_aka_authentication_reject{} = _EAP ->
				EapPacket1 = #eap_packet{code = failure, identifier = EapID},
				send_diameter_response(SessionID, AuthReqType,
						?'DIAMETER_BASE_RESULT-CODE_AUTHENTICATION_REJECTED',
						OHost, ORealm, EapPacket1, PortServer, Request, StateData),
				{stop, {shutdown, SessionID}, StateData};
			#eap_aka_client_error{client_error_code = _Code} ->
				EapPacket1 = #eap_packet{code = failure, identifier = EapID},
				send_diameter_response(SessionID, AuthReqType,
						?'DIAMETER_BASE_RESULT-CODE_AUTHENTICATION_REJECTED',
						OHost, ORealm, EapPacket1, PortServer, Request, StateData),
				{stop, {shutdown, SessionID}, StateData}
		end
	catch
		_:_Reason ->
			EapPacket2 = #eap_packet{code = failure, identifier = EapID},
			send_diameter_response(SessionID, AuthReqType,
					?'DIAMETER_BASE_RESULT-CODE_INVALID_AVP_BITS', OHost, ORealm,
					EapPacket2, PortServer, Request, StateData),
			{stop, {shutdown, SessionID}, StateData}
	end;
challenge({#radius{id = RadiusID, authenticator = RequestAuthenticator,
		attributes = RequestAttributes} = Request, RadiusFsm},
		#statedata{eap_id = EapID, session_id = SessionID,
		res = RES, kaut = Kaut} = StateData) ->
	NewStateData = StateData#statedata{request = Request,
			radius_fsm = RadiusFsm},
	try
		EapMessage = radius_attributes:fetch(?EAPMessage, RequestAttributes),
		EapPacket = ocs_eap_codec:eap_packet(EapMessage),
		#eap_packet{code = response, type = ?AKAprime, identifier = EapID,
				data = Data} = EapPacket,
		case ocs_eap_codec:eap_aka(Data) of
			#eap_aka_challenge{res = RES, checkcode = <<>>, mac = MAC} = EAP ->
				Data1 = ocs_eap_codec:eap_aka(EAP#eap_aka_challenge{mac = <<0:128>>}),
				EapMessage1 = ocs_eap_codec:eap_packet(EapPacket#eap_packet{data = Data1}),
				case crypto:hmac(sha256, Kaut, EapMessage1, 16) of
					MAC ->
						EapPacket1 = #eap_packet{code = success, identifier = EapID},
						send_radius_response(EapPacket1, ?AccessAccept, [], RadiusID,
								RequestAuthenticator, RequestAttributes, NewStateData),
						{stop, {shutdown, SessionID}, NewStateData};
					_ ->
						EapPacket1 = #eap_packet{code = request,
								type = ?AKAprime, identifier = EapID,
								data = #eap_aka_notification{notification = 16384}},
						send_radius_response(EapPacket1, ?AccessChallenge, [], RadiusID,
								RequestAuthenticator, RequestAttributes, NewStateData),
						{next_state, failure, NewStateData, ?TIMEOUT}
				end;
			#eap_aka_challenge{checkcode = <<>>} = _EAP ->
				EapPacket1 = #eap_packet{code = request,
						type = ?AKAprime, identifier = EapID,
						data = #eap_aka_notification{notification = 16384}},
				send_radius_response(EapPacket1, ?AccessChallenge, [], RadiusID,
						RequestAuthenticator, RequestAttributes, NewStateData),
				{next_state, failure, NewStateData, ?TIMEOUT};
			% #eap_aka_synchronization_failure{auts = _AUTS} = _EAP ->
			% @todo handle resynchronization
			#eap_aka_authentication_reject{} = _EAP ->
				EapPacket1 = #eap_packet{code = failure, identifier = EapID},
				send_radius_response(EapPacket1, ?AccessReject, [], RadiusID,
						RequestAuthenticator, RequestAttributes, NewStateData),
				{stop, {shutdown, SessionID}, NewStateData};
			#eap_aka_client_error{client_error_code = _Code} ->
				EapPacket1 = #eap_packet{code = failure, identifier = EapID},
				send_radius_response(EapPacket1, ?AccessReject, [], RadiusID,
						RequestAuthenticator, RequestAttributes, NewStateData),
				{stop, {shutdown, SessionID}, StateData}
		end
	catch
		_:_Reason ->
			EapPacket2 = #eap_packet{code = failure, identifier = EapID},
			send_radius_response(EapPacket2, ?AccessReject, [], RadiusID,
					RequestAuthenticator, RequestAttributes, NewStateData),
			{stop, {shutdown, SessionID}, NewStateData}
	end.

-spec failure(Event, StateData) -> Result
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
%%		gen_fsm:send_event/2} in the <b>failure</b> state.
%% @@see //stdlib/gen_fsm:StateName/2
%% @private
failure(timeout, #statedata{session_id = SessionID} = StateData)->
	{stop, {shutdown, SessionID}, StateData};
failure({#radius{id = RadiusID, authenticator = RequestAuthenticator,
		attributes = RequestAttributes} = Request, RadiusFsm},
		#statedata{eap_id = EapID, session_id = SessionID} = StateData) ->
	NewStateData = StateData#statedata{request = Request,
			radius_fsm = RadiusFsm},
	try
		EapMessage = radius_attributes:fetch(?EAPMessage, RequestAttributes),
		#eap_packet{code = response, type = ?AKAprime, identifier = EapID,
				data = Data} = ocs_eap_codec:eap_packet(EapMessage),
		case ocs_eap_codec:eap_aka(Data) of
			#eap_aka_notification{mac = undefined} = _EAP ->
				EapPacket1 = #eap_packet{code = failure, identifier = EapID},
				send_radius_response(EapPacket1, ?AccessReject, [], RadiusID,
						RequestAuthenticator, RequestAttributes, NewStateData),
				{stop, {shutdown, SessionID}, NewStateData}
			% #eap_aka_notification{mac = MAC} = _EAP ->
			% @todo Handle notification when P=0
		end
	catch
		_:_Reason ->
			EapPacket2 = #eap_packet{code = failure, identifier = EapID},
			send_radius_response(EapPacket2, ?AccessReject, [], RadiusID,
					RequestAuthenticator, RequestAttributes, NewStateData),
			{stop, {shutdown, SessionID}, NewStateData}
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
handle_event(_Event, StateName, StateData) ->
	{next_state, StateName, StateData, ?TIMEOUT}.

-spec handle_sync_event(Event, From, StateName, StateData) -> Result
	when
		Event :: term(),
		From :: {Pid :: pid(), Tag :: term()},
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
		NextStateName :: atom(),
		NewStateData :: statedata(),
		Timeout :: non_neg_integer() | infinity,
		Reason :: normal | term().
%% @doc Handle an event sent with
%% 	{@link //stdlib/gen_fsm:sync_send_all_state_event/2.
%% 	gen_fsm:sync_send_all_state_event/2,3}.
%% @see //stdlib/gen_fsm:handle_sync_event/4
%% @private
%%
handle_sync_event(_Event, _From, StateName, StateData) ->
	{reply, ok, StateName, StateData}.

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
handle_info(_Info, StateName, StateData) ->
	{next_state, StateName, StateData, ?TIMEOUT}.

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

-spec code_change(OldVsn, StateName, StateData, Extra) -> Result
	when
		OldVsn :: (Vsn :: term() | {down, Vsn :: term()}),
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

-spec send_radius_response(EapPacket, RadiusCode, ResponseAttributes, RadiusID,
		RequestAuthenticator, RequestAttributes, StateData) -> ok
	when
		EapPacket :: #eap_packet{},
		RadiusCode :: integer(),
		ResponseAttributes :: radius_attributes:attributes(),
		RadiusID :: integer(),
		RequestAuthenticator :: [byte()],
		RequestAttributes :: radius_attributes:attributes(),
		StateData :: #statedata{}.
%% @doc Sends a RADIUS Access/Challenge, Reject or Accept packet to peer.
%% @hidden
send_radius_response(EapPacket, RadiusCode, ResponseAttributes,
		RadiusID, RequestAuthenticator, RequestAttributes,
		#statedata{server_address = ServerAddress, server_port = ServerPort,
		client_address = ClientAddress, client_port = ClientPort,
		secret = Secret, radius_fsm = RadiusFsm} = _StateData) ->
	EapPacketData = ocs_eap_codec:eap_packet(EapPacket),
	AttrList1 = radius_attributes:add(?EAPMessage,
			EapPacketData, ResponseAttributes),
	AttrList2 = radius_attributes:add(?MessageAuthenticator,
			<<0:128>>, AttrList1),
	Attributes1 = radius_attributes:codec(AttrList2),
	Length = size(Attributes1) + 20,
	MessageAuthenticator = crypto:hmac(md5, Secret, [<<RadiusCode, RadiusID,
			Length:16>>, RequestAuthenticator, Attributes1]),
	AttrList3 = radius_attributes:store(?MessageAuthenticator,
			MessageAuthenticator, AttrList2),
	Attributes2 = radius_attributes:codec(AttrList3),
	ResponseAuthenticator = crypto:hash(md5, [<<RadiusCode, RadiusID,
			Length:16>>, RequestAuthenticator, Attributes2, Secret]),
	Response = #radius{code = RadiusCode, id = RadiusID,
			authenticator = ResponseAuthenticator, attributes = Attributes2},
	ResponsePacket = radius:codec(Response),
	case RadiusCode of
		?AccessAccept ->
			ok = ocs_log:auth_log(radius, {ServerAddress, ServerPort},
					{ClientAddress, ClientPort}, accept,
					RequestAttributes, AttrList3);
		?AccessReject ->
			ok = ocs_log:auth_log(radius, {ServerAddress, ServerPort},
					{ClientAddress, ClientPort}, reject,
					RequestAttributes, AttrList3);
		_ ->
			ok
	end,
	radius:response(RadiusFsm, {response, ResponsePacket}).

-spec send_diameter_response(SId, AuthType, ResultCode,
		OriginHost, OriginRealm, EapPacket, PortServer,
		Request, StateData) -> ok
	when
		SId :: string(),
		AuthType :: integer(),
		ResultCode :: integer(),
		OriginHost :: binary(),
		OriginRealm :: binary(),
		EapPacket :: none | #eap_packet{},
		PortServer :: pid(),
		Request :: #diameter_eap_app_DER{},
		StateData :: #statedata{}.
%% @doc Log DIAMETER event and send appropriate DIAMETER answer to
%% 	ocs_diameter_auth_port_server.
%% @hidden
send_diameter_response(SId, AuthType, ResultCode,
		OriginHost, OriginRealm, none, PortServer,
		#diameter_eap_app_DER{} = Request,
		#statedata{server_address = ServerAddress,
		server_port = ServerPort, client_address = ClientAddress,
		client_port = ClientPort} = _StateData) when is_list(SId),
		is_integer(AuthType), is_integer(ResultCode),
		is_binary(OriginHost), is_binary(OriginRealm),
		is_pid(PortServer) ->
	Server = {ServerAddress, ServerPort},
	Client= {ClientAddress, ClientPort},
	Answer = #diameter_eap_app_DEA{'Session-Id' = SId,
			'Auth-Application-Id' = ?EAP_APPLICATION_ID,
			'Auth-Request-Type' = AuthType,
			'Result-Code' = ResultCode,
			'Origin-Host' = OriginHost,
			'Origin-Realm' = OriginRealm},
	ok = ocs_log:auth_log(diameter, Server, Client, Request, Answer),
	gen_server:cast(PortServer, {self(), Answer});
send_diameter_response(SId, AuthType, ResultCode,
		OriginHost, OriginRealm, #eap_packet{} = EapPacket,
		PortServer, #diameter_eap_app_DER{} = Request,
		#statedata{server_address = ServerAddress,
		server_port = ServerPort, client_address = ClientAddress,
		client_port = ClientPort} = _StateData) when is_list(SId),
		is_integer(AuthType), is_integer(ResultCode),
		is_binary(OriginHost), is_binary(OriginRealm),
		is_pid(PortServer) ->
	Server = {ServerAddress, ServerPort},
	Client= {ClientAddress, ClientPort},
	try
		EapData = ocs_eap_codec:eap_packet(EapPacket),
		Answer = #diameter_eap_app_DEA{'Session-Id' = SId,
				'Auth-Application-Id' = ?EAP_APPLICATION_ID,
				'Auth-Request-Type' = AuthType,
				'Result-Code' = ResultCode,
				'Origin-Host' = OriginHost,
				'Origin-Realm' = OriginRealm,
				'EAP-Payload' = [EapData]},
		ok = ocs_log:auth_log(diameter, Server, Client, Request, Answer),
		gen_server:cast(PortServer, {self(), Answer})
	catch
		_:_ ->
			Answer1 = #diameter_eap_app_DEA{'Session-Id' = SId,
					'Auth-Application-Id' = ?EAP_APPLICATION_ID,
					'Auth-Request-Type' = AuthType,
					'Result-Code' = ?'DIAMETER_BASE_RESULT-CODE_UNABLE_TO_COMPLY',
					'Origin-Host' = OriginHost,
					'Origin-Realm' = OriginRealm},
			ok = ocs_log:auth_log(diameter, Server, Client, Request, Answer1),
			gen_server:cast(PortServer, {self(), Answer1})
	end.

-spec compressed_imsi(IMSI) -> IMSI
	when
		IMSI :: binary().
%% @doc Compress or decompress an IMSI.
%%
%% 	See 3GPP 33.402 14.1 Temporary identity generation.
%% @private
compressed_imsi(<<15:4, _:60/bits>> = IMSI) ->
	B = << <<A, B>> || <<A:4, B:4>> <= IMSI >>,
	lists:flatten([integer_to_list(C) || <<C>> <= B, C /= 15]);
compressed_imsi(IMSI) when is_binary(IMSI) ->
	L1 = [list_to_integer([C]) || <<C>> <= IMSI],
	L2 = lists:duplicate(16 - length(L1), 15),
	L3 = L2 ++ L1,
	<< <<D:4>> || D <- L3 >>.

-spec encrypt_imsi(CompressedIMSI, Key) -> Pseudonym
	when
		CompressedIMSI :: binary(),
		Key :: {N, Kpseu},
		N :: pos_integer(),
		Kpseu :: binary(),
		Pseudonym :: binary().
%% @doc Create an encrypted temporary identity.
%%
%% 	See 3GPP 33.402 14.1 Temporary identity generation.
%% @private
encrypt_imsi(CompressedIMSI, {N, Kpseu} = _Key)
		when size(CompressedIMSI) == 8, size(Kpseu) == 16 ->
	Pad = crypto:strong_rand_bytes(8),
	PaddedIMSI = <<CompressedIMSI/binary, Pad/binary>>,
	EncryptedIMSI = crypto:block_encrypt(aes_ecb, Kpseu, PaddedIMSI),
	TaggedIMSI = <<?TEMP_TAG:6, N:4, EncryptedIMSI/binary, 0:6>>,
	binary:part(base64:encode(TaggedIMSI), 0, 23).

-spec decrypt_imsi(Pseudonym, Keys) -> CompressedIMSI
	when
		Pseudonym :: binary(),
		Keys :: [Key],
		Key :: {N, Kpseu},
		N :: pos_integer(),
		Kpseu :: binary(),
		CompressedIMSI :: binary().
%% @doc Decrypt a temporary identity.
%%
%% 	See 3GPP 33.402 14.1 Temporary identity generation.
%% @private
decrypt_imsi(Pseudonym, Keys)
		when size(Pseudonym) == 23, is_list(Keys) ->
	TaggedIMSI = base64:decode(<<Pseudonym/binary, $A>>),
	<<?TEMP_TAG:6, N:4, EncryptedIMSI:16/binary, _:6>> = TaggedIMSI,
	{_, Kpseu} = lists:keyfind(N, 1, Keys),
	PaddedIMSI = crypto:block_decrypt(aes_ecb, Kpseu, EncryptedIMSI),
	binary:part(PaddedIMSI, 0, 8).

-spec prf(K, S, N) -> MK
	when
		K :: binary(),
		S :: binary(),
		N :: pos_integer(),
		MK :: binary().
%% @doc Pseudo-Random Number Function (PRF).
%%
%% 	See RFC5448 3.4.
%% @private
prf(K, S, N) when is_binary(K), is_binary(S), is_integer(N), N > 1 ->
	prf(K, S, N, 1, <<>>, []).
%% @hidden
prf(_, _, N, P, _, Acc) when P > N ->
	iolist_to_binary(lists:reverse(Acc));
prf(K, S, N, P, T1, Acc) ->
	T2 = crypto:hmac(sha256, K, <<T1/binary, S/binary, P>>),
	prf(K, S, N, P + 1, T2, [T2 | Acc]).
