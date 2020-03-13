-module(test_utils).

-export([wait_report_device_status/1, wait_report_channel_status/1,
         wait_channel_data/1,
         wait_state_channel_message/1, wait_state_channel_message/8,
         tmp_dir/0, tmp_dir/1]).

-include_lib("helium_proto/include/blockchain_state_channel_v1_pb.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("device_worker.hrl").
-include("lorawan_vars.hrl").

-define(BASE_TMP_DIR, "./_build/test/tmp").
-define(BASE_TMP_DIR_TEMPLATE, "XXXXXXXXXX").

wait_report_device_status(Expected) ->
    try
        receive
            {report_status, Body} ->
                Got = jsx:decode(Body, [return_maps]), 
                case match_map(Expected, Got) of
                    true ->
                        ok;
                    false ->
                        ct:pal("FAILED got: ~n~p~n expected: ~n~p", [Got, Expected]),
                        ct:fail("wait_report_device_status data failed")
                end
        after 250 ->
                ct:fail("wait_report_device_status timeout")
        end
    catch
        _Class:_Reason:Stacktrace ->
            ct:pal("wait_report_device_status stacktrace ~p~n", [Stacktrace]),
            ct:fail("wait_report_device_status failed")
    end.

wait_report_channel_status(Expected) ->
    try
        receive
            {report_status, Body} ->
                Got = jsx:decode(Body, [return_maps]), 
                case match_map(Expected, Got) of
                    true ->
                        ok;
                    false ->
                        ct:pal("FAILED got: ~n~p~n expected: ~n~p", [Got, Expected]),
                        ct:fail("wait_report_channel_status data failed")
                end
        after 250 ->
                ct:fail("wait_report_channel_status timeout")
        end
    catch
        _Class:_Reason:Stacktrace ->
            ct:pal("wait_report_channel_status stacktrace ~p~n", [Stacktrace]),
            ct:fail("wait_report_channel_status failed")
    end.

wait_channel_data(Expected) ->
    try
        receive
            {channel_data, Body} ->
                Got = jsx:decode(Body, [return_maps]), 
                case match_map(Expected, Got) of
                    true ->
                        ok;
                    false ->
                        ct:pal("FAILED got: ~n~p~n expected: ~n~p", [Got, Expected]),
                        ct:fail("wait_channel_data failed")
                end
        after 250 ->
                ct:fail("wait_channel_data timeout")
        end
    catch
        _Class:_Reason:Stacktrace ->
            ct:pal("wait_channel_data stacktrace ~p~n", [Stacktrace]),
            ct:fail("wait_channel_data failed")
    end.

wait_state_channel_message(Timeout) ->
    try
        receive
            {client_data, undefined, Data} ->
                try blockchain_state_channel_v1_pb:decode_msg(Data, blockchain_state_channel_message_v1_pb) of
                    #blockchain_state_channel_message_v1_pb{msg={response, Resp}} ->
                        #blockchain_state_channel_response_v1_pb{accepted=true} = Resp,
                        ok;
                    _Else ->
                        ct:fail("wait_state_channel_message wrong message ~p ", [_Else])
                catch
                    _E:_R ->
                        ct:fail("wait_state_channel_message failed to decode ~p ~p", [Data, {_E, _R}])
                end
        after Timeout ->
                ct:fail("wait_state_channel_message timeout")
        end
    catch
        _Class:_Reason:Stacktrace ->
            ct:pal("wait_state_channel_message stacktrace ~p~n", [Stacktrace]),
            ct:fail("wait_state_channel_message failed")
    end.

wait_state_channel_message(Msg, Device, FrameData, Type, FPending, Ack, Fport, FCnt) ->
    try
        receive
            {client_data, undefined, Data} ->
                try blockchain_state_channel_v1_pb:decode_msg(Data, blockchain_state_channel_message_v1_pb) of
                    #blockchain_state_channel_message_v1_pb{msg={response, Resp}} ->
                        #blockchain_state_channel_response_v1_pb{accepted=true, downlink=Packet} = Resp,
                        ct:pal("packet ~p", [Packet]),
                        Frame = deframe_packet(Packet, router_device:app_s_key(Device)),
                        ct:pal("~p", [lager:pr(Frame, ?MODULE)]),
                        ?assertEqual(FrameData, Frame#frame.data),
                        %% we queued an unconfirmed packet
                        ?assertEqual(Type, Frame#frame.mtype),
                        ?assertEqual(FPending, Frame#frame.fpending),
                        ?assertEqual(Ack, Frame#frame.ack),
                        ?assertEqual(Fport, Frame#frame.fport),
                        ?assertEqual(FCnt, Frame#frame.fcnt),
                        {ok, Frame};
                    _Else ->
                        ct:fail("wait_state_channel_message wrong message ~p for ~p", [_Else, Msg])
                catch _E:_R ->
                        ct:fail("wait_state_channel_message failed to decode ~p ~p for ~p", [Data, {_E, _R} , Msg])
                end
        after 1000 ->
                ct:fail("wait_state_channel_message timeout for ~p", [Msg])
        end
    catch
        _Class:_Reason:Stacktrace ->
            ct:pal("wait_state_channel_message stacktrace ~p~n", [Stacktrace]),
            ct:fail("wait_state_channel_message failed")
    end.

%%--------------------------------------------------------------------
%% @doc
%% generate a tmp directory to be used as a scratch by eunit tests
%% @end
%%-------------------------------------------------------------------
tmp_dir() ->
    os:cmd("mkdir -p " ++ ?BASE_TMP_DIR),
    create_tmp_dir(?BASE_TMP_DIR_TEMPLATE).
tmp_dir(SubDir) ->
    Path = filename:join(?BASE_TMP_DIR, SubDir),
    os:cmd("mkdir -p " ++ Path),
    create_tmp_dir(Path ++ "/" ++ ?BASE_TMP_DIR_TEMPLATE).

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec match_map(map(), map()) -> boolean().
match_map(Expected, Got) ->
    case maps:size(Expected) == maps:size(Got) of
        false ->
            false;
        true ->
            maps:fold(
              fun(_K, _V, false) ->
                      false;
                 (K, V, true) when is_function(V) ->
                      V(maps:get(K, Got, undefined));
                 (K, '_', true) ->
                      maps:is_key(K, Got);
                 (K, V, true) ->
                      case maps:get(K, Got, undefined) of
                          V -> true;
                          _ -> false
                      end
              end,
              true,
              Expected)
    end.

-spec create_tmp_dir(list()) -> list().
create_tmp_dir(Path)->
    nonl(os:cmd("mktemp -d " ++  Path)).

nonl([$\n|T]) -> nonl(T);
nonl([H|T]) -> [H|nonl(T)];
nonl([]) -> [].

deframe_packet(Packet, SessionKey) ->
    <<MType:3, _MHDRRFU:3, _Major:2, DevAddrReversed:4/binary, ADR:1, RFU:1, ACK:1, FPending:1,
      FOptsLen:4, FCnt:16/little-unsigned-integer, FOpts:FOptsLen/binary, PayloadAndMIC/binary>> = Packet#packet_pb.payload,
    DevAddr = lorawan_utils:reverse(DevAddrReversed),
    {FPort, FRMPayload} = lorawan_utils:extract_frame_port_payload(PayloadAndMIC),
    Data = lorawan_utils:reverse(lorawan_utils:cipher(FRMPayload, SessionKey, MType band 1, DevAddr, FCnt)),
    ct:pal("FOpts ~p", [FOpts]),
    #frame{mtype=MType, devaddr=DevAddr, adr=ADR, rfu=RFU, ack=ACK, fpending=FPending,
           fcnt=FCnt, fopts=lorawan_mac_commands:parse_fdownopts(FOpts), fport=FPort, data=Data}.


