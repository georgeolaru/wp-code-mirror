<?php
/**
 * Plugin Name: WP Code Mirror
 * Description: Test across many WordPress sites from one working codebase.
 * Version: 0.1.0
 * Author: George Olaru
 */

declare(strict_types=1);

if ( ! defined( 'ABSPATH' ) ) {
	exit;
}

require_once __DIR__ . '/includes/class-wp-code-mirror-config-repository.php';
require_once __DIR__ . '/includes/class-wp-code-mirror-host-bridge.php';
require_once __DIR__ . '/includes/class-wp-code-mirror-admin-page.php';
require_once __DIR__ . '/includes/class-wp-code-mirror-paths.php';

function wp_code_mirror_bootstrap(): void {
	if ( ! is_admin() ) {
		return;
	}

	$paths = new WP_Code_Mirror_Paths( __DIR__ );

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
