<?php

declare(strict_types=1);

$plugin_dir = dirname(__DIR__);
require_once $plugin_dir . '/includes/class-wp-code-mirror-host-bridge.php';

$runtime = sys_get_temp_dir() . '/wp-code-mirror-service-fallback-' . bin2hex(random_bytes(4));
mkdir($runtime, 0777, true);
register_shutdown_function(
	static function () use ($runtime): void {
		foreach (glob($runtime . '/*') ?: [] as $path) {
			unlink($path);
		}
		rmdir($runtime);
	}
);

file_put_contents(
	$runtime . '/wp-code-mirror-fallback-test-status.json',
	json_encode(['updated_at' => gmdate('c'), 'overall_state' => 'CLEAN'])
);

$bridge = new WP_Code_Mirror_Host_Bridge('/bin/false', '/bin/false', '/definitely/missing/config.json', $runtime);
$status = $bridge->get_service_status('fallback-test');
if (($status['installed'] ?? true) !== false || ($status['running'] ?? true) !== false) {
	throw new RuntimeException('Historical status must not make an uninstalled service appear installed.');
}

echo "PASS: service fallback ignores historical status for installation state\n";
