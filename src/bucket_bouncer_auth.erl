%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2012 Basho Technologies, Inc.  All Rights Reserved.
%%
%% -------------------------------------------------------------------

-module(bucket_bouncer_auth).

-include("bucket_bouncer.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([authenticate/2,
         request_signature/4]).

%% ===================================================================
%% Public API
%% ===================================================================

-spec authenticate(term(), [string()]) -> ok | {error, atom()}.
authenticate(RD, [KeyId, Signature]) ->
    case bucket_bouncer_utils:get_admin_creds() of
        {ok, {AdminKeyId, AdminSecret}} ->
            CalculatedSignature = signature(AdminSecret, RD),
            lager:debug("Presented Signature: ~p~nCalculated Signature: ~p~n",
                        [Signature, CalculatedSignature]),
            case KeyId == AdminKeyId andalso
                check_auth(Signature, CalculatedSignature) of
                true ->
                    ok;
                _ ->
                    {error, invalid_authentication}
            end;
        _ ->
            {error, invalid_authentication}
    end.

%% Calculate a signature for inclusion in a client request.
-type http_verb() :: 'GET' | 'HEAD' | 'PUT' | 'POST' | 'DELETE'.
-spec request_signature(http_verb(),
                        [{string(), string()}],
                        string(),
                        string()) -> string().
request_signature(HttpVerb, RawHeaders, Path, KeyData) ->
    Headers = normalize_headers(RawHeaders),
    BashoHeaders = extract_basho_headers(Headers),
    case proplists:is_defined("x-basho-date", Headers) of
        true ->
            Date = "\n";
        false ->
            Date = [proplists:get_value("date", Headers), "\n"]
    end,
    case proplists:get_value("content-md5", Headers) of
        undefined ->
            CMD5 = [];
        CMD5 ->
            ok
    end,
    case proplists:get_value("content-type", Headers) of
        undefined ->
            ContentType = [];
        ContentType ->
            ok
    end,
    STS = [atom_to_list(HttpVerb),
           "\n",
           CMD5,
           "\n",
           ContentType,
           "\n",
           Date,
           BashoHeaders,
           Path],
    base64:encode_to_string(
      crypto:sha_mac(KeyData, STS)).

%% ===================================================================
%% Internal functions
%% ===================================================================

signature(KeyData, RD) ->
    Headers = normalize_headers(get_request_headers(RD)),
    BashoHeaders = extract_basho_headers(Headers),
    Resource = wrq:path(RD),
    case proplists:is_defined("x-basho-date", Headers) of
        true ->
            Date = "\n";
        false ->
            Date = [wrq:get_req_header("date", RD), "\n"]
    end,
    case wrq:get_req_header("content-md5", RD) of
        undefined ->
            CMD5 = [];
        CMD5 ->
            ok
    end,
    case wrq:get_req_header("content-type", RD) of
        undefined ->
            ContentType = [];
        ContentType ->
            ok
    end,
    STS = [atom_to_list(wrq:method(RD)), "\n",
           CMD5,
           "\n",
           ContentType,
           "\n",
           Date,
           BashoHeaders,
           Resource],
    base64:encode_to_string(
      crypto:sha_mac(KeyData, STS)).

check_auth(PresentedSignature, CalculatedSignature) ->
    PresentedSignature == CalculatedSignature.

get_request_headers(RD) ->
    mochiweb_headers:to_list(wrq:req_headers(RD)).

normalize_headers(Headers) ->
    FilterFun =
        fun({K, V}, Acc) ->
                LowerKey = string:to_lower(any_to_list(K)),
                [{LowerKey, V} | Acc]
        end,
    ordsets:from_list(lists:foldl(FilterFun, [], Headers)).

extract_basho_headers(Headers) ->
    FilterFun =
        fun({K, V}, Acc) ->
                case lists:prefix("x-basho-", K) of
                    true ->
                        [[K, ":", V, "\n"] | Acc];
                    false ->
                        Acc
                end
        end,
    ordsets:from_list(lists:foldl(FilterFun, [], Headers)).

any_to_list(V) when is_list(V) ->
    V;
any_to_list(V) when is_atom(V) ->
    atom_to_list(V);
any_to_list(V) when is_binary(V) ->
    binary_to_list(V);
any_to_list(V) when is_integer(V) ->
    integer_to_list(V).

%% ===================================================================
%% Eunit tests
%% ===================================================================

-ifdef(TEST).

%% Test cases for the examples provided by Amazon here:
%% http://docs.amazonwebservices.com/AmazonS3/latest/dev/index.html?RESTAuthentication.html

auth_test_() ->
    {spawn,
     [
      {setup,
       fun setup/0,
       fun teardown/1,
       fun(_X) ->
               [
                example_get_object(),
                example_put_object(),
                example_list(),
                example_fetch(),
                example_delete(),
                example_upload(),
                example_list_all_buckets(),
                example_unicode_keys()
               ]
       end
      }]}.

setup() ->
    application:set_env(bucket_bouncer, moss_root_host, "s3.amazonaws.com").

teardown(_) ->
    application:unset_env(bucket_bouncer, moss_root_host).

test_fun(Description, ExpectedSignature, CalculatedSignature) ->
    {Description,
     fun() ->
             [
              ?_assert(check_auth(ExpectedSignature, CalculatedSignature))
             ]
     end
    }.

example_get_object() ->
    KeyData = "uV3F3YluFJax1cknvbcGwgjvx4QpvB+leU8dUj2o",
    Method = 'GET',
    Version = {1, 1},
    Path = "/photos/puppy.jpg",
    Headers =
        mochiweb_headers:make([{"Host", "johnsmith.s3.amazonaws.com"},
                               {"Date", "Tue, 27 Mar 2007 19:36:42 +0000"}]),
    RD = wrq:create(Method, Version, Path, Headers),
    ExpectedSignature = "xXjDGYUmKxnwqr5KXNPGldn5LbA=",
    CalculatedSignature = calculate_signature(KeyData, RD),
    test_fun("example get object test", ExpectedSignature, CalculatedSignature).

example_put_object() ->
    KeyData = "uV3F3YluFJax1cknvbcGwgjvx4QpvB+leU8dUj2o",
    Method = 'PUT',
    Version = {1, 1},
    Path = "/photos/puppy.jpg",
    Headers =
        mochiweb_headers:make([{"Host", "johnsmith.s3.amazonaws.com"},
                               {"Content-Type", "image/jpeg"},
                               {"Content-Length", 94328},
                               {"Date", "Tue, 27 Mar 2007 21:15:45 +0000"}]),
    RD = wrq:create(Method, Version, Path, Headers),
    ExpectedSignature = "hcicpDDvL9SsO6AkvxqmIWkmOuQ=",
    CalculatedSignature = calculate_signature(KeyData, RD),
    test_fun("example put object test", ExpectedSignature, CalculatedSignature).

example_list() ->
    KeyData = "uV3F3YluFJax1cknvbcGwgjvx4QpvB+leU8dUj2o",
    Method = 'GET',
    Version = {1, 1},
    Path = "/?prefix=photos&max-keys=50&marker=puppy",
    Headers =
        mochiweb_headers:make([{"User-Agent", "Mozilla/5.0"},
                               {"Host", "johnsmith.s3.amazonaws.com"},
                               {"Date", "Tue, 27 Mar 2007 19:42:41 +0000"}]),
    RD = wrq:create(Method, Version, Path, Headers),
    ExpectedSignature = "jsRt/rhG+Vtp88HrYL706QhE4w4=",
    CalculatedSignature = calculate_signature(KeyData, RD),
    test_fun("example list test", ExpectedSignature, CalculatedSignature).

example_fetch() ->
    KeyData = "uV3F3YluFJax1cknvbcGwgjvx4QpvB+leU8dUj2o",
    Method = 'GET',
    Version = {1, 1},
    Path = "/?acl",
    Headers =
        mochiweb_headers:make([{"Host", "johnsmith.s3.amazonaws.com"},
                               {"Date", "Tue, 27 Mar 2007 19:44:46 +0000"}]),
    RD = wrq:create(Method, Version, Path, Headers),
    ExpectedSignature = "thdUi9VAkzhkniLj96JIrOPGi0g=",
    CalculatedSignature = calculate_signature(KeyData, RD),
    test_fun("example fetch test", ExpectedSignature, CalculatedSignature).

example_delete() ->
    KeyData = "uV3F3YluFJax1cknvbcGwgjvx4QpvB+leU8dUj2o",
    Method = 'DELETE',
    Version = {1, 1},
    Path = "/johnsmith/photos/puppy.jpg",
    Headers =
        mochiweb_headers:make([{"User-Agent", "dotnet"},
                               {"Host", "s3.amazonaws.com"},
                               {"Date", "Tue, 27 Mar 2007 21:20:27 +0000"},
                               {"x-amz-date", "Tue, 27 Mar 2007 21:20:26 +0000"}]),
    RD = wrq:create(Method, Version, Path, Headers),
    ExpectedSignature = "k3nL7gH3+PadhTEVn5Ip83xlYzk=",
    CalculatedSignature = calculate_signature(KeyData, RD),
    test_fun("example delete test", ExpectedSignature, CalculatedSignature).

%% @TODO This test case should be specified using two separate
%% X-Amz-Meta-ReviewedBy headers, but Amazon strictly interprets
%% section 4.2 of RFC 2616 and forbids anything but commas seperating
%% field values of headers with the same field name whereas webmachine
%% inserts a comma and a space between the field values. This is
%% probably something that can be changed in webmachine without any
%% ill effect, but that needs to be verified. For now, the test case
%% is specified using a singled X-Amz-Meta-ReviewedBy header with
%% multiple field values.
example_upload() ->
    KeyData = "uV3F3YluFJax1cknvbcGwgjvx4QpvB+leU8dUj2o",
    Method = 'PUT',
    Version = {1, 1},
    Path = "/db-backup.dat.gz",
    Headers =
        mochiweb_headers:make([{"User-Agent", "curl/7.15.5"},
                               {"Host", "static.johnsmith.net:8080"},
                               {"Date", "Tue, 27 Mar 2007 21:06:08 +0000"},
                               {"x-amz-acl", "public-read"},
                               {"content-type", "application/x-download"},
                               {"Content-MD5", "4gJE4saaMU4BqNR0kLY+lw=="},
                               {"X-Amz-Meta-ReviewedBy", "joe@johnsmith.net,jane@johnsmith.net"},
                               %% {"X-Amz-Meta-ReviewedBy", "jane@johnsmith.net"},
                               {"X-Amz-Meta-FileChecksum", "0x02661779"},
                               {"X-Amz-Meta-ChecksumAlgorithm", "crc32"},
                               {"Content-Disposition", "attachment; filename=database.dat"},
                               {"Content-Encoding", "gzip"},
                               {"Content-Length", 5913339}]),
    RD = wrq:create(Method, Version, Path, Headers),
    ExpectedSignature = "C0FlOtU8Ylb9KDTpZqYkZPX91iI=",
    CalculatedSignature = calculate_signature(KeyData, RD),
    test_fun("example upload test", ExpectedSignature, CalculatedSignature).

example_list_all_buckets() ->
    KeyData = "uV3F3YluFJax1cknvbcGwgjvx4QpvB+leU8dUj2o",
    Method = 'GET',
    Version = {1, 1},
    Path = "/",
    Headers =
        mochiweb_headers:make([{"Host", "s3.amazonaws.com"},
                               {"Date", "Wed, 28 Mar 2007 01:29:59 +0000"}]),
    RD = wrq:create(Method, Version, Path, Headers),
    ExpectedSignature = "Db+gepJSUbZKwpx1FR0DLtEYoZA=",
    CalculatedSignature = calculate_signature(KeyData, RD),
    test_fun("example list all buckts test", ExpectedSignature, CalculatedSignature).

example_unicode_keys() ->
    KeyData = "uV3F3YluFJax1cknvbcGwgjvx4QpvB+leU8dUj2o",
    Method = 'GET',
    Version = {1, 1},
    Path = "/dictionary/fran%C3%A7ais/pr%c3%a9f%c3%a8re",
    Headers =
        mochiweb_headers:make([{"Host", "s3.amazonaws.com"},
                               {"Date", "Wed, 28 Mar 2007 01:49:49 +0000"}]),
    RD = wrq:create(Method, Version, Path, Headers),
    ExpectedSignature = "dxhSBHoI6eVSPcXJqEghlUzZMnY=",
    CalculatedSignature = calculate_signature(KeyData, RD),
    test_fun("example unicode keys test", ExpectedSignature, CalculatedSignature).

-endif.