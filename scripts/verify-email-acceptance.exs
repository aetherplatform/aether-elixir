# Operator-reviewed evidence is bound to the exact source and built package.
# Contains no recipients, codes, callback URLs or credentials.
required = fn key -> System.get_env(key) || raise("Missing release gate: #{key}") end
proof = required.("AETHER_ELIXIR_EMAIL_ACCEPTANCE_JSON") |> Jason.decode!()
sha = required.("GITHUB_SHA")
package = "aether_sdk-#{Mix.Project.config()[:version]}.tar"
digest = :crypto.hash(:sha256, File.read!(package)) |> Base.encode16(case: :lower)

valid =
  proof["source_commit"] == sha and proof["package_sha256"] == digest and
    proof["oauth_email_callback_exchange_userinfo"] == true and
    proof["passwordless_email_completion_exchange_userinfo"] == true and
    proof["sms_delivery"] in ["verified", "unverified"] and
    is_binary(proof["reviewed_by"]) and proof["reviewed_by"] != ""

if not valid, do: raise("Controlled email acceptance does not match this source and package")
IO.puts("Controlled email acceptance matches this exact package. SMS: #{proof["sms_delivery"]}.")
