#!/bin/sh
# SPDX-License-Identifier: MIT
# QEMU-only negative validation: all test credentials are synthetic.
set -eu
umask 077

credential=/etc/parallax/credentials/negative_ci.json
validate_log=/tmp/parallax-negative-validate.log
apply_log=/tmp/parallax-negative-apply.log
active=/etc/parallax/generated/active.json
store=/etc/parallax/generated
synthetic_uuid=00000000-0000-4000-8000-000000000001

cleanup() {
  uci -q delete parallax.negative_ci || :
  uci -q delete parallax.negative_rule || :
  uci -q delete parallax.main.unexpected_option || :
  uci set parallax.main.default_outbound=direct || :
  uci commit parallax || :
  rm -f "$credential" "$validate_log" "$apply_log"
}
trap cleanup EXIT

test -f "$active"
original_hash="$(sha256sum "$active" | cut -d ' ' -f1)"
original_count="$(find "$store" -maxdepth 1 -type f -name 'rev-*.json' | wc -l)"
test -n "$original_hash"

reject() {
  label="$1"
  if parallax validate >"$validate_log" 2>&1; then
    echo "FAIL: $label accepted by validate" >&2
    exit 1
  fi
  if parallax apply --config-only >"$apply_log" 2>&1; then
    echo "FAIL: $label accepted by apply" >&2
    exit 1
  fi
  if grep -Fq "$synthetic_uuid" "$validate_log" "$apply_log"; then
    echo "FAIL: $label leaked a synthetic credential" >&2
    exit 1
  fi
  if [ "$(sha256sum "$active" | cut -d ' ' -f1)" != "$original_hash" ]; then
    echo "FAIL: $label changed active.json" >&2
    exit 1
  fi
  if [ "$(find "$store" -maxdepth 1 -type f -name 'rev-*.json' | wc -l)" != "$original_count" ]; then
    echo "FAIL: $label created a revision" >&2
    exit 1
  fi
  echo "PASS: reject $label (validate/apply denied; active SHA256 and revision count unchanged)"
}

keys="$(sing-box generate reality-keypair)"
public="$(printf '%s\n' "$keys" | awk '/^PublicKey:/ { print $2 }')"
test "$(printf '%s' "$public" | wc -c)" -eq 43
unset keys

mkdir -p /etc/parallax/credentials
chmod 0700 /etc/parallax/credentials
printf '{"uuid":"invalid"}\n' >"$credential"
chmod 0600 "$credential"

uci set parallax.negative_ci=profile
uci set parallax.negative_ci.enabled=1
uci set parallax.negative_ci.protocol=vless
uci set parallax.negative_ci.server=example.net
uci set parallax.negative_ci.port=443
uci set parallax.negative_ci.credential_ref=negative_ci
uci set parallax.negative_ci.tls_sni=example.net
uci set parallax.negative_ci.reality_public_key="$public"
uci set parallax.negative_ci.reality_short_id=01234567
uci commit parallax
reject invalid_uuid

printf '{"uuid":"%s"}\n' "$synthetic_uuid" >"$credential"
chmod 0600 "$credential"

uci set 'parallax.negative_ci.server=bad host'
uci commit parallax
reject invalid_hostname
uci set parallax.negative_ci.server=example.net

uci set parallax.negative_ci.port=70000
uci commit parallax
reject invalid_port
uci set parallax.negative_ci.port=443

uci set parallax.negative_ci.reality_public_key=bad_key
uci commit parallax
reject invalid_reality_key
uci set parallax.negative_ci.reality_public_key="$public"

uci set parallax.negative_ci.reality_short_id=zz
uci commit parallax
reject invalid_short_id
uci set parallax.negative_ci.reality_short_id=01234567

uci set parallax.negative_ci.unexpected_option=1
uci commit parallax
reject unknown_profile_option
uci delete parallax.negative_ci.unexpected_option

uci set parallax.negative_ci.credential_ref=missing_negative_ci
uci commit parallax
reject missing_credential_reference
uci set parallax.negative_ci.credential_ref=negative_ci

uci set parallax.main.default_outbound=nonexistent_profile
uci commit parallax
reject missing_outbound_reference
uci set parallax.main.default_outbound=direct

uci set parallax.main.unexpected_option=1
uci commit parallax
reject unknown_main_option
uci delete parallax.main.unexpected_option

uci set parallax.negative_rule=rule
uci set parallax.negative_rule.enabled=1
uci set parallax.negative_rule.match=domain_suffix
uci add_list parallax.negative_rule.value=example.net
uci set parallax.negative_rule.outbound=direct
uci set parallax.negative_rule.priority=99999
uci commit parallax
reject invalid_priority

uci set parallax.negative_rule.priority=100
uci set parallax.negative_rule.match=unsupported_match
uci commit parallax
reject unsupported_matcher

uci set parallax.negative_rule.match=ip_cidr
uci -q delete parallax.negative_rule.value
uci add_list parallax.negative_rule.value=300.1.2.3/33
uci commit parallax
reject invalid_ipv4_cidr

# Explicitly reject a malformed rollback ID before touching revision state.
if parallax rollback invalid-revision >"$apply_log" 2>&1; then
  echo 'FAIL: accepted invalid rollback revision ID' >&2
  exit 1
fi
test "$(sha256sum "$active" | cut -d ' ' -f1)" = "$original_hash"
test "$(find "$store" -maxdepth 1 -type f -name 'rev-*.json' | wc -l)" = "$original_count"
echo 'PASS: invalid rollback ID rejected; active state preserved'
echo 'PASS: all QEMU negative validation scenarios passed'
