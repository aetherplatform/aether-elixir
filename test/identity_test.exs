defmodule Aether.SDK.IdentityTest do
  use ExUnit.Case, async: true
  alias Aether.SDK.{Error, Identity}
  alias Aether.SDK.Identity.{CallbackAuthorized, CallbackDenied, PKCE}
  alias Aether.SDK.Types.Identity, as: Types

  @origin "https://identity.example.test"
  @redirect "https://app.example.test/auth/callback"
  @verifier String.duplicate("v", 43)
  @challenge Base.url_encode64(:crypto.hash(:sha256, @verifier), padding: false)
  @challenge_id "c7b3b0f4-6a07-46ef-a83d-7765b9f239f7"

  test "configuration, discovery-only client and credentials redaction" do
    assert {:ok, client} = Identity.new(base_url: @origin <> "/ignored")
    assert client.base_url == @origin
    assert client.client_id == nil
    assert client.timeout == 15_000
    assert client.max_retries == 2
    assert {:ok, %{max_retries: 0}} = Identity.new(base_url: @origin, max_retries: 0)

    for options <- [
          [base_url: "https://user:secret@example.test"],
          [base_url: @origin <> "?token=x"],
          [base_url: @origin <> "#"],
          [base_url: "file:///x"],
          [base_url: @origin, client_secret: "x"],
          [base_url: @origin, client_id: ""],
          [base_url: @origin, timeout: 0]
        ] do
      assert {:error, %Error{code: "invalid_configuration"}} = Identity.new(options)
    end

    assert {:error, %Error{}} = Identity.confidential(base_url: @origin, client_id: "a")

    assert {:ok, confidential} =
             Identity.confidential(
               base_url: @origin,
               client_id: "a",
               client_secret: "secret-marker"
             )

    refute inspect(confidential) =~ "secret-marker"
  end

  test "PKCE proofs are fresh S256 and redacted" do
    %PKCE{} = proof = Identity.generate_pkce()
    assert proof.code_verifier != Identity.generate_pkce().code_verifier
    assert proof.code_challenge_method == "S256"
    assert byte_size(proof.code_verifier) == 43

    assert proof.code_challenge ==
             Base.url_encode64(:crypto.hash(:sha256, proof.code_verifier), padding: false)

    refute inspect(proof) =~ proof.code_verifier
    assert byte_size(Identity.generate_state()) == 43
  end

  test "authorization binds registered client, exact callback and S256 without exposing verifier" do
    {:ok, client} = Identity.new(base_url: @origin, client_id: "public-app")

    request = %{
      redirect_uri: @redirect,
      scope: "openid profile",
      state: "state",
      code_challenge: @challenge
    }

    assert {:ok, url} = Identity.authorize(client, request)
    uri = URI.parse(url)
    assert uri.path == "/oauth/authorize"
    query = URI.decode_query(uri.query)
    assert query["client_id"] == "public-app"
    assert query["code_challenge_method"] == "S256"
    assert query["response_type"] == "code"
    refute Map.has_key?(query, "code_verifier")

    for bad <- [
          %{client_id: "foreign"},
          %{redirect_uri: "http://example.test/cb"},
          %{redirect_uri: @redirect <> "?x=1"},
          %{state: String.duplicate("é", 513)},
          %{code_verifier: @verifier}
        ] do
      assert {:error, %Error{}} = Identity.authorization_url(client, Map.merge(request, bad))
    end
  end

  test "callbacks reject mismatched redirect/state, duplicates, fragments and mixed results" do
    assert {:ok, %CallbackAuthorized{code: "opaque-code", state: "state"} = result} =
             Identity.validate_callback(
               @redirect <> "?code=opaque-code&state=state",
               @redirect,
               "state"
             )

    refute inspect(result) =~ "opaque-code"

    assert {:ok, %CallbackDenied{error: "access_denied"}} =
             Identity.validate_callback(
               @redirect <> "?error=access_denied&state=state&error_description=secret",
               @redirect,
               "state"
             )

    for suffix <- [
          "?code=x&state=wrong",
          "?code=x&state=state&state=state",
          "?code=x&state=state&%73tate=state",
          "?code=x&error=access_denied&state=state",
          "?error=arbitrary&state=state",
          "?code=x&state=state#",
          "?code=&state=state",
          "?state=state",
          "?code=x&state=state&unknown=x",
          "?code=x&state=state&error_description=x",
          "?code=%xx&state=state"
        ] do
      assert {:error, %Error{code: "invalid_callback"}} =
               Identity.validate_callback(@redirect <> suffix, @redirect, "state")
    end

    assert {:error, %Error{}} =
             Identity.validate_callback(
               "https://evil.test/auth/callback?code=x&state=state",
               @redirect,
               "state"
             )

    assert {:error, %Error{}} =
             Identity.validate_callback(@redirect <> "/?code=x&state=state", @redirect, "state")

    assert {:ok, %CallbackAuthorized{}} =
             Identity.validate_callback(
               "http://127.0.0.1:5000/cb?code=x&state=s",
               "http://127.0.0.1:5000/cb",
               "s"
             )
  end

  test "Kerma-style discovery, PKCE callback exchange and userinfo use public protocol" do
    plug = fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.request_path do
        "/.well-known/openid-configuration" ->
          json(conn, discovery())

        "/oauth/token" ->
          assert conn.query_params["client_id"] == "kerma"

          assert Plug.Conn.get_req_header(conn, "authorization") == [
                   "Basic " <> Base.encode64("kerma:server-secret")
                 ]

          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          form = URI.decode_query(raw)
          assert form["code_verifier"] == @verifier
          assert form["redirect_uri"] == @redirect
          assert form["code"] == "opaque-code"
          json(conn, token_response())

        "/oauth/userinfo" ->
          assert conn.query_params["client_id"] == "kerma"
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer access-marker"]
          json(conn, %{"sub" => "pairwise-user", "product_claim" => "custom"})
      end
    end

    {:ok, client} =
      Identity.confidential(
        base_url: @origin,
        client_id: "kerma",
        client_secret: "server-secret",
        req_options: [plug: plug]
      )

    assert {:ok, %Types.OpenIdConfiguration{issuer: @origin}} =
             Identity.get_open_id_configuration(client)

    assert {:ok, _} =
             Identity.authorization_url(client, %{
               redirect_uri: @redirect,
               scope: "openid",
               state: "state",
               code_challenge: @challenge
             })

    assert {:ok, %CallbackAuthorized{code: code}} =
             Identity.validate_callback(
               @redirect <> "?code=opaque-code&state=state",
               @redirect,
               "state"
             )

    assert {:ok, %Types.TokenResponse{access_token: token} = result} =
             Identity.exchange_oauth_token(client, Map.put(code_request(), :code, code))

    refute inspect(result) =~ "access-marker"

    assert {:ok, %Types.UserInfo{sub: "pairwise-user"}} =
             Identity.get_user_info(client, %{access_token: token})
  end

  test "public code exchange, refresh and revocation omit credentials and reject machine grants" do
    client =
      public(fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == []
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["client_id"] == "public-app"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = URI.decode_query(raw)
        assert body["client_id"] == "public-app"
        refute Map.has_key?(body, "client_secret")

        if conn.request_path == "/oauth/revoke",
          do: Plug.Conn.send_resp(conn, 200, ""),
          else: json(conn, token_response())
      end)

    assert {:ok, %Types.TokenResponse{}} = Identity.exchange_oauth_token(client, code_request())

    assert {:ok, %Types.TokenResponse{}} =
             Identity.exchange_oauth_token(client, %{
               grant_type: "refresh_token",
               refresh_token: "refresh-marker"
             })

    assert {:ok, _} = Identity.revoke_oauth_token(client, %{token: "access-marker"})

    assert {:error, %Error{}} =
             Identity.exchange_oauth_token(client, %{
               grant_type: "client_credentials",
               audience: "events",
               scope: "read"
             })

    assert {:error, %Error{code: "unauthorized_client"}} =
             Identity.introspect_oauth_token(client, %{token: "access-marker"})

    for bad <- [%{client_secret: "never"}, %{client_id: "foreign"}, %{code_verifier: "short"}] do
      assert {:error, %Error{}} =
               Identity.exchange_oauth_token(client, Map.merge(code_request(), bad))
    end
  end

  test "confidential machine tokens and introspection encode Basic credentials" do
    plug = fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == [
               "Basic " <> Base.encode64("client%3Aid:secret%3A+space")
             ]

      if conn.request_path == "/oauth/introspect",
        do: json(conn, %{"active" => true}),
        else: json(conn, token_response())
    end

    {:ok, client} =
      Identity.confidential(
        base_url: @origin,
        client_id: "client:id",
        client_secret: "secret: space",
        req_options: [plug: plug]
      )

    assert {:ok, %Types.TokenResponse{}} =
             Identity.exchange_oauth_token(client, %{
               grant_type: "client_credentials",
               audience: "aether-events",
               scope: "events:read"
             })

    assert {:ok, %Types.IntrospectionResponse{active: true}} =
             Identity.introspect_oauth_token(client, %{token: "token"})
  end

  test "passwordless email/SMS, resend timing and distinct completion outcome structs" do
    for channel <- ["email", "sms"] do
      client =
        public(fn conn ->
          assert conn.query_string == "client_id=public-app"
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          request = Jason.decode!(body)
          assert request["client_id"] == "public-app"
          assert request["channel"] == channel
          json(conn, start_response(), 202)
        end)

      assert {:ok, %Types.PasswordlessStartResponse{resend_after: 87}} =
               Identity.start_passwordless(client, start_request(channel))
    end

    outcomes = [
      {%{"status" => "authorized", "code" => "opaque-code", "state" => "original"},
       Types.PasswordlessAuthorized},
      {%{
         "status" => "hosted_completion_required",
         "continuation_url" => @origin <> "/oauth/passwordless/continue?handoff=secret",
         "expires_in" => 120
       }, Types.PasswordlessHostedCompletionRequired},
      {%{
         "status" => "custom_completion_required",
         "continuation" => "handle",
         "expires_in" => 120,
         "requirements" => requirements()
       }, Types.PasswordlessCustomCompletionRequired}
    ]

    for {outcome, type} <- outcomes do
      client = public(fn conn -> json(conn, outcome) end)
      assert {:ok, result} = Identity.verify_passwordless(client, verify_request())
      assert result.__struct__ == type

      if type == Types.PasswordlessHostedCompletionRequired do
        assert {:ok, url} = Identity.continuation_url(client, result)
        assert url == outcome["continuation_url"]
      end
    end

    for outcome <- [
          %{"status" => "authorized", "code" => "code", "state" => nil},
          %{"status" => "denied", "error" => "access_denied", "state" => "original"}
        ] do
      client = public(fn conn -> json(conn, outcome) end)

      assert {:ok, _} =
               Identity.complete_passwordless(client, %{
                 continuation: "handle",
                 code_verifier: @verifier,
                 decision: "deny"
               })
    end
  end

  test "passwordless rejects context override, changed client and malformed proofs before sending" do
    client = public(fn _ -> flunk("invalid requests must not be sent") end)

    for bad <- [
          %{organization_id: "foreign"},
          %{client_id: "foreign"},
          %{code_challenge_method: "plain"},
          %{identifier: " "},
          %{nonce: String.duplicate("é", 513)},
          %{redirect_uri: @redirect <> "#"}
        ] do
      assert {:error, %Error{}} =
               Identity.start_passwordless(client, Map.merge(start_request(), bad))
    end

    assert {:error, %Error{}} =
             Identity.verify_passwordless(client, Map.put(verify_request(), :code, "12345"))

    assert {:error, %Error{}} =
             Identity.verify_passwordless(
               client,
               Map.put(verify_request(), :code_verifier, "bad")
             )

    assert {:error, %Error{}} =
             Identity.complete_passwordless(client, %{
               continuation: "handle",
               code_verifier: @verifier,
               decision: "approve",
               completion_mode: "custom"
             })
  end

  test "handoffs require exact origin/path and one opaque query credential" do
    for url <- [
          "https://evil.test/oauth/passwordless/continue?handoff=x",
          @origin <> "/other?handoff=x",
          @origin <> "/oauth/passwordless/continue?handoff=x&handoff=y",
          @origin <> "/oauth/passwordless/continue?handoff=x&next=evil",
          @origin <> "/oauth/passwordless/continue?handoff=x#",
          @origin <> "/oauth/passwordless/continue?handoff="
        ] do
      client =
        public(fn conn ->
          json(conn, %{
            "status" => "hosted_completion_required",
            "continuation_url" => url,
            "expires_in" => 120
          })
        end)

      assert {:error, %Error{code: "invalid_response"}} =
               Identity.verify_passwordless(client, verify_request())
    end
  end

  test "malformed success bodies never become authentication success" do
    for body <- [
          %{"status" => "authorized", "code" => "", "state" => nil},
          %{"status" => "authorized", "code" => "x"},
          %{"status" => "denied", "error" => "access_denied", "state" => nil},
          %{
            "status" => "custom_completion_required",
            "continuation" => "x",
            "expires_in" => 120,
            "requirements" => Map.put(requirements(), "aether_terms_version", nil)
          },
          %{
            "status" => "hosted_completion_required",
            "continuation_url" => @origin <> "/oauth/passwordless/continue?handoff=x",
            "expires_in" => 301
          }
        ] do
      assert {:error, %Error{code: "invalid_response"}} =
               Identity.verify_passwordless(
                 public(fn conn -> json(conn, body) end),
                 verify_request()
               )
    end

    for body <- [
          %{},
          Map.put(token_response(), "access_token", ""),
          Map.put(token_response(), "expires_in", 0)
        ] do
      assert {:error, %Error{}} =
               Identity.exchange_oauth_token(
                 public(fn conn -> json(conn, body) end),
                 code_request()
               )
    end
  end

  test "authentication mutations always use one attempt despite caller retry settings" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    client =
      public(fn conn ->
        Agent.update(attempts, &(&1 + 1))

        conn
        |> Plug.Conn.put_resp_header("retry-after", "0")
        |> json(%{"error" => %{"code" => "TEMPORARILY_UNAVAILABLE"}}, 503)
      end)

    options = [retry: true, max_retries: 3]

    actions = [
      fn -> Identity.start_passwordless(client, start_request(), options) end,
      fn -> Identity.verify_passwordless(client, verify_request(), options) end,
      fn ->
        Identity.complete_passwordless(
          client,
          %{continuation: "x", code_verifier: @verifier, decision: "approve"},
          options
        )
      end,
      fn -> Identity.exchange_oauth_token(client, code_request(), options) end,
      fn ->
        Identity.exchange_oauth_token(
          client,
          %{grant_type: "refresh_token", refresh_token: "x"},
          options
        )
      end,
      fn -> Identity.revoke_oauth_token(client, %{token: "x"}, options) end
    ]

    Enum.each(actions, fn action -> assert {:error, %Error{attempts: 1}} = action.() end)
    assert Agent.get(attempts, & &1) == length(actions)
  end

  test "authentication error details and arbitrary codes cannot leak returned secrets" do
    client =
      public(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-request-id", "token-marker")
        |> Plug.Conn.put_resp_header("retry-after", "12")
        |> json(
          %{
            "error" => %{
              "code" => "token-marker",
              "message" => "secret-marker",
              "details" => %{"code" => "otp-marker"}
            }
          },
          400
        )
      end)

    assert {:error, %Error{} = error} = Identity.exchange_oauth_token(client, code_request())
    assert error.code == "request_failed"
    assert error.request_id == nil
    assert error.details == nil
    assert error.cause == nil
    assert error.retry[:retry_after_seconds] == 12
    refute error.message =~ "marker"
  end

  test "discovery pins issuer/endpoints and permits registration-free metadata reads" do
    for metadata <- [
          Map.put(discovery(), "issuer", "https://evil.test"),
          Map.put(discovery(), "token_endpoint", "https://evil.test/oauth/token"),
          Map.put(discovery(), "authorization_endpoint", @origin <> "/wrong"),
          Map.put(discovery(), "code_challenge_methods_supported", [])
        ] do
      {:ok, client} =
        Identity.new(base_url: @origin, req_options: [plug: fn conn -> json(conn, metadata) end])

      assert {:error, %Error{code: "invalid_response"}} =
               Identity.get_open_id_configuration(client)
    end

    {:ok, client} =
      Identity.new(
        base_url: @origin,
        req_options: [
          plug: fn conn ->
            case conn.request_path do
              "/.well-known/openid-configuration" ->
                json(conn, discovery())

              "/.well-known/jwks.json" ->
                json(conn, %{
                  "keys" => [
                    %{
                      "kty" => "OKP",
                      "kid" => "key1",
                      "alg" => "EdDSA",
                      "use" => "sig",
                      "crv" => "Ed25519",
                      "x" => "public"
                    }
                  ]
                })

              "/.well-known/scopes" ->
                json(conn, %{"scopes" => []})
            end
          end
        ]
      )

    assert {:ok, _} = Identity.get_open_id_configuration(client)
    assert {:ok, _} = Identity.get_oauth_jwks(client)
    assert {:ok, _} = Identity.list_oauth_scopes(client)
    assert {:error, _} = Identity.get_open_id_configuration(client, %{unexpected: true})
  end

  defp public(plug) do
    {:ok, client} =
      Identity.new(base_url: @origin, client_id: "public-app", req_options: [plug: plug])

    client
  end

  defp json(conn, body, status \\ 200),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))

  defp code_request,
    do: %{
      grant_type: "authorization_code",
      code: "opaque-code",
      redirect_uri: @redirect,
      code_verifier: @verifier
    }

  defp token_response,
    do: %{
      "access_token" => "access-marker",
      "token_type" => "Bearer",
      "expires_in" => 300,
      "refresh_token" => "refresh-marker",
      "id_token" => "opaque-id-token"
    }

  defp start_request(channel \\ "email"),
    do: %{
      identifier: "person@example.test",
      channel: channel,
      redirect_uri: @redirect,
      scope: "openid",
      state: "original",
      code_challenge: @challenge,
      code_challenge_method: "S256"
    }

  defp start_response,
    do: %{
      "transaction" => "transaction-marker",
      "challenge_id" => @challenge_id,
      "expires_in" => 300,
      "resend_after" => 87,
      "transaction_expires_in" => 600
    }

  defp verify_request,
    do: %{
      transaction: "transaction-marker",
      challenge_id: @challenge_id,
      identifier: "person@example.test",
      channel: "email",
      code: "123456",
      code_verifier: @verifier
    }

  defp requirements,
    do: %{
      "registration" => true,
      "consent" => true,
      "scopes" => ["openid"],
      "aether_terms_version" => "2026-01",
      "aether_privacy_version" => "2026-01"
    }

  defp discovery,
    do: %{
      "issuer" => @origin,
      "authorization_endpoint" => @origin <> "/oauth/authorize",
      "token_endpoint" => @origin <> "/oauth/token",
      "jwks_uri" => @origin <> "/.well-known/jwks.json",
      "response_types_supported" => ["code"],
      "grant_types_supported" => ["authorization_code", "refresh_token", "client_credentials"],
      "code_challenge_methods_supported" => ["S256"]
    }
end
