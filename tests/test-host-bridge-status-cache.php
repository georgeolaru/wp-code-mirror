<?php

declare(strict_types=1);

$plugin_dir = dirname(__DIR__);
require_once $plugin_dir . '/includes/class-wp-code-mirror-host-bridge.php';

$test_root = sys_get_temp_dir() . '/wp-code-mirror-status-cache-' . bin2hex(random_bytes(4));
$source = $test_root . '/source';
$target = $test_root . '/target';
$runtime = $test_root . '/runtime';
$config_path = $test_root . '/config.json';

mkdir($source . '/wp-content/themes', 0777, true);
mkdir($source . '/wp-content/plugins', 0777, true);
mkdir($target . '/wp-content/themes', 0777, true);
mkdir($target . '/wp-content/plugins', 0777, true);
mkdir($runtime, 0777, true);

register_shutdown_function(
	static function () use ($test_root): void {
		if (! is_dir($test_root)) {
			return;
		}
		$iterator = new RecursiveIteratorIterator(
			new RecursiveDirectoryIterator($test_root, FilesystemIterator::SKIP_DOTS),
			RecursiveIteratorIterator::CHILD_FIRST
		);
		foreach ($iterator as $entry) {
			$entry->isDir() ? rmdir($entry->getPathname()) : unlink($entry->getPathname());
		}
		rmdir($test_root);
	}
);

$write_config = static function (bool $active, string $site_path, array $plugins = [], array $excludes = []) use ($config_path, $source): void {
	file_put_contents(
		$config_path,
		json_encode(
			[
				'source_site' => $source,
				'targets' => [
					[
						'label' => 'cache-test',
						'site_path' => $site_path,
						'active' => $active,
						'themes' => [],
						'plugins' => $plugins,
						'mu_plugins' => [],
					],
				],
				'rsync_excludes' => $excludes,
			],
			JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES
		)
	);
};

$status_path = $runtime . '/wp-code-mirror-cache-test-status.json';
$write_stale_clean_status = static function () use ($status_path, $source, $target): void {
	file_put_contents(
		$status_path,
		json_encode(
			[
				'updated_at' => '2000-01-01T00:00:00Z',
				'source_site' => $source,
				'overall_state' => 'CLEAN',
				'rsync_excludes' => [],
				'targets' => [
					[
						'label' => 'cache-test',
						'site_path' => $target,
						'active' => true,
						'state' => 'CLEAN',
						'items' => [],
					],
				],
			]
		)
	);
};

$bridge = new WP_Code_Mirror_Host_Bridge(
	$plugin_dir . '/scripts/wp-code-sync.sh',
	$plugin_dir . '/scripts/wp-code-sync-service.sh',
	$config_path,
	$runtime
);

$write_config(false, $target);
$write_stale_clean_status();
$inactive_status = $bridge->get_sync_status('cache-test');
if (($inactive_status['overall_state'] ?? '') !== 'MISSING' || ($inactive_status['targets'][0]['reason'] ?? '') !== 'INACTIVE') {
	throw new RuntimeException('Inactive target must invalidate stale CLEAN status.');
}

$missing_path = $test_root . '/missing-target';
$write_config(true, $missing_path);
$write_stale_clean_status();
touch($config_path, time() + 2);
$missing_status = $bridge->get_sync_status('cache-test');
if (($missing_status['overall_state'] ?? '') !== 'MISSING' || ($missing_status['targets'][0]['reason'] ?? '') !== 'TARGET_MISSING') {
	throw new RuntimeException('Missing target must invalidate stale CLEAN status.');
}

$write_config(true, $target, ['missing-plugin'], ['*.map']);
$write_stale_clean_status();
touch($status_path, time() + 4);
$changed_components_status = $bridge->get_sync_status('cache-test');
if (($changed_components_status['overall_state'] ?? '') !== 'ERROR') {
	throw new RuntimeException('Changed components/exclusions must invalidate stale CLEAN status even when the cache file is newer.');
}

$write_config(true, $target);
$write_stale_clean_status();
$stale = json_decode((string) file_get_contents($status_path), true);
$stale['targets'][0]['active'] = false;
file_put_contents($status_path, json_encode($stale));
touch($status_path, time() + 5);
$reactivated_status = $bridge->get_sync_status('cache-test');
if (($reactivated_status['targets'][0]['active'] ?? false) !== true) {
	throw new RuntimeException('Reactivated target must invalidate cached inactive status.');
}

rename($source . '/wp-content/plugins', $source . '/wp-content/plugins-missing');
$write_stale_clean_status();
touch($status_path, time() + 6);
$missing_source_status = $bridge->get_sync_status('cache-test');
if (($missing_source_status['ok'] ?? true) !== false || stripos((string) ($missing_source_status['message'] ?? ''), 'source plugins directory missing') === false) {
	throw new RuntimeException('Missing source tree must invalidate stale CLEAN status.');
}

echo "PASS: host bridge invalidates stale sync status\n";
