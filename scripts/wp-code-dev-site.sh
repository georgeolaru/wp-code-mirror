#!/usr/bin/env bash

# Headless provisioning for a mirrored Studio dev site: activate the Pixelgrade stack, seed a
# Plus license/account from a reference site, and (optionally) import a full starter — all via
# `studio wp`, no wp-admin interaction. Companion to wp-code-target.sh.

set -euo pipefail

DEFAULT_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
if [[ -n "${PATH:-}" ]]; then
  PATH="${PATH}:${DEFAULT_PATH}"
else
  PATH="${DEFAULT_PATH}"
fi
export PATH

DEFAULT_LICENSE_SOURCE="${HOME}/Studio/pixelgrade-integrated-check"

usage() {
  cat <<'EOF'
Usage:
  bash scripts/wp-code-dev-site.sh provision <site_path> [options]
      --starter <id>             Full starter to import headlessly (e.g. rosa-lt). Skipped
                                 when the site already has content (see --force-starter).
      --license-from <path>      Reference site to copy the Pixelgrade account/license state
                                 from (default: ~/Studio/pixelgrade-integrated-check)
      --no-license               Skip the license/account seeding
      --force-starter            Import the starter even into a non-empty site
EOF
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

note() {
  printf '\033[2m$\033[0m \033[1m%s\033[0m\n' "$*"
}

swp() {
  note "studio wp $*"
  studio wp "$@" --path "${SITE_PATH}" </dev/null
}

cmd_provision() {
  SITE_PATH="$1"; shift
  local starter="" license_from="${DEFAULT_LICENSE_SOURCE}" seed_license=1 force_starter=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --starter) starter="$2"; shift 2 ;;
      --license-from) license_from="$2"; shift 2 ;;
      --no-license) seed_license=0; shift ;;
      --force-starter) force_starter=1; shift ;;
      *) fail "unknown option for provision: $1" ;;
    esac
  done

  [[ -d "${SITE_PATH}/wp-content" ]] || fail "not a WordPress site: ${SITE_PATH}"
  command -v studio >/dev/null 2>&1 || fail "missing required tool: studio"

  # 1. Activate the stack — theme first, then every stack plugin that exists on disk.
  if [[ -d "${SITE_PATH}/wp-content/themes/anima-lt" ]]; then
    swp theme activate anima-lt
  fi
  local plugin
  local -a to_activate=()
  for plugin in pixelgrade-assistant style-manager nova-blocks pixelgrade-plus pixelgrade-devmode; do
    [[ -d "${SITE_PATH}/wp-content/plugins/${plugin}" ]] && to_activate+=("${plugin}")
  done
  if [[ ${#to_activate[@]:-0} -gt 0 ]]; then
    swp plugin activate "${to_activate[@]}"
  fi

  # 2. Seed the Pixelgrade account + license from the reference site: the account-identity user
  #    meta and ONLY the `account` slice of pixassist_options (journals/starter state stay out).
  if [[ ${seed_license} -eq 1 ]]; then
    if [[ -d "${license_from}/wp-content" ]]; then
      local seed
      note "studio wp eval <export account state> --path ${license_from}"
      seed="$(studio wp eval '
        $meta = array();
        foreach ( array( "pixassist_oauth_token", "pixassist_oauth_token_secret", "pixassist_user_ID", "pixelgrade_user_login", "pixelgrade_user_email", "pixelgrade_display_name" ) as $k ) {
          $meta[ $k ] = get_user_meta( 1, $k, true );
        }
        $options = (array) get_option( "pixassist_options" );
        echo json_encode( array(
          "meta"    => $meta,
          "account" => isset( $options["account"] ) ? $options["account"] : null,
        ) );
      ' --path "${license_from}" </dev/null)"

      if [[ -n "${seed}" && "${seed}" != "null" ]]; then
        note "studio wp eval <import account state> --path ${SITE_PATH}"
        SEED_JSON="${seed}" studio wp eval '
          $seed = json_decode( getenv( "SEED_JSON" ), true );
          if ( ! is_array( $seed ) ) { echo "seed_decode_failed"; return; }
          foreach ( (array) $seed["meta"] as $k => $v ) {
            if ( "" !== $v && null !== $v ) { update_user_meta( 1, $k, $v ); }
          }
          if ( ! empty( $seed["account"] ) ) {
            $options = (array) get_option( "pixassist_options" );
            $options["account"] = $seed["account"];
            update_option( "pixassist_options", $options );
          }
          echo "account seeded";
        ' --path "${SITE_PATH}" </dev/null
        echo
      else
        echo "Warning: could not export account state from ${license_from} — continuing unlicensed." >&2
      fi
    else
      echo "Warning: license reference site not found (${license_from}) — continuing unlicensed." >&2
    fi

    # Entitlements come from the devmode force flags — deterministic and offline, the same
    # mechanism the canonical integrated-check site uses. This is NOT the genuine licensing
    # path; test real license activation separately (it stays fully exercisable in the UI).
    if [[ -d "${SITE_PATH}/wp-content/plugins/pixelgrade-plus" ]]; then
      note "studio wp eval <enable devmode force_license + force_entitlements>"
      studio wp eval '
        $dev = (array) get_option( "pixelgrade_plus_dev", array() );
        $dev["force_license"]      = true;
        $dev["force_entitlements"] = true;
        update_option( "pixelgrade_plus_dev", $dev );
        echo "plus dev entitlements forced";
      ' --path "${SITE_PATH}" </dev/null
      echo
    fi
  fi

  # 3. Warm the theme config so the starter catalog resolves (the get_config anti-stampede guard
  #    may return empty on the very first request after activation).
  local tries=0 count="0"
  while [[ ${tries} -lt 5 ]]; do
    count="$(studio wp eval 'echo count( pixassist_get_starter_sites_data()["starters"] );' --path "${SITE_PATH}" 2>/dev/null </dev/null || echo 0)"
    [[ "${count}" =~ ^[0-9]+$ ]] || count=0
    [[ "${count}" -gt 0 ]] && break
    tries=$((tries + 1))
    sleep 2
  done
  echo "Starter catalog: ${count} designs available."

  # 4. Optional headless full-starter import, guarded: never into a site that already has content.
  if [[ -n "${starter}" ]]; then
    local content_count
    content_count="$(studio wp eval '
      $q = new WP_Query( array( "post_type" => array( "post", "page", "attachment" ), "post_status" => array( "publish", "inherit" ), "posts_per_page" => 1, "fields" => "ids" ) );
      echo (int) $q->found_posts;
    ' --path "${SITE_PATH}" 2>/dev/null </dev/null || echo 99)"
    [[ "${content_count}" =~ ^[0-9]+$ ]] || content_count=99

    # A fresh WordPress ships Hello world + Sample Page (+ a privacy draft) — up to 3 items.
    if [[ "${content_count}" -gt 3 && ${force_starter} -ne 1 ]]; then
      echo "Site is not empty (${content_count} content items) — skipping the '${starter}' import. Use --force-starter to override." >&2
    else
      note "studio wp eval <import full starter: ${starter}> (this downloads media; takes a few minutes)"
      STARTER_ID="${starter}" studio wp eval '
        $id = sanitize_key( getenv( "STARTER_ID" ) );
        $starters = pixassist_get_starter_sites_data();
        $match = null;
        foreach ( (array) $starters["starters"] as $s ) {
          if ( isset( $s["id"] ) && $s["id"] === $id ) { $match = $s; break; }
        }
        if ( ! $match ) { echo "starter_not_found: ", $id; return; }
        $result = PixelgradeAssistant()->starter_content->import_starter( $match["id"], $match["baseRestUrl"] );
        if ( $result instanceof WP_REST_Response ) { $result = $result->get_data(); }
        echo isset( $result["code"] ) ? $result["code"] : "unknown", ": ", isset( $result["message"] ) ? $result["message"] : "";
      ' --path "${SITE_PATH}" </dev/null
      echo
    fi
  fi

  echo "Provisioned: ${SITE_PATH}"
}

main() {
  local command="${1:-}"
  [[ -n "${command}" ]] || { usage; exit 1; }
  shift || true

  case "${command}" in
    provision)
      [[ $# -ge 1 ]] || fail "provision requires a <site_path>"
      local site_path="$1"; shift
      cmd_provision "${site_path}" "$@"
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage
      fail "unknown command: ${command}"
      ;;
  esac
}

main "$@"
