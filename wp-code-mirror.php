<?php
/**
 * Plugin Name: WP Code Mirror
 * Plugin URI:  https://github.com/georgeolaru/wp-code-mirror
 * Description: Mirror in-development theme and plugin code across multiple WordPress test sites.
 * Version: 0.1.0
 * Author: George Olaru
 * Author URI:  https://github.com/georgeolaru
 * Requires at least: 6.0
 * Tested up to: 7.0
 * Requires PHP: 7.4
 * Text Domain: wp-code-mirror
 * License: MIT
 * License URI: https://opensource.org/licenses/MIT
 */

declare(strict_types=1);

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

require_once __DIR__ . '/includes/class-wp-code-mirror-config-repository.php';
require_once __DIR__ . '/includes/class-wp-code-mirror-host-bridge.php';
require_once __DIR__ . '/includes/class-wp-code-mirror-admin-page.php';
require_once __DIR__ . '/includes/class-wp-code-mirror-paths.php';

function wp_code_mirror_maybe_migrate_legacy_config( WP_Code_Mirror_Paths $paths ): void {
	if ( file_exists( $paths->config_path() ) || ! file_exists( $paths->legacy_config_path() ) ) {
		return;
	}

	if ( ! is_dir( $paths->config_dir() ) ) {
		wp_mkdir_p( $paths->config_dir() );
	}

	copy( $paths->legacy_config_path(), $paths->config_path() );
}

function wp_code_mirror_bootstrap(): void {
	if ( ! is_admin() ) {
		return;
	}

	$paths = new WP_Code_Mirror_Paths( __DIR__ );
	wp_code_mirror_maybe_migrate_legacy_config( $paths );

	$repository = new WP_Code_Mirror_Config_Repository( $paths->config_path() );
	$bridge     = new WP_Code_Mirror_Host_Bridge(
		$paths->scripts_dir() . '/wp-code-sync.sh',
		$paths->scripts_dir() . '/wp-code-sync-service.sh',
		$paths->config_path(),
		$paths->tmp_dir()
	);

	$page = new WP_Code_Mirror_Admin_Page( $repository, $bridge, __FILE__ );
	$page->register();
}

add_action( 'plugins_loaded', 'wp_code_mirror_bootstrap' );
