<?php

declare(strict_types=1);

$plugin_dir = dirname(__DIR__);
require_once $plugin_dir . '/includes/class-wp-code-mirror-host-bridge.php';
require_once $plugin_dir . '/includes/class-wp-code-mirror-config-repository.php';
require_once $plugin_dir . '/includes/class-wp-code-mirror-admin-page.php';

class WP_Code_Mirror_Recording_Bridge extends WP_Code_Mirror_Host_Bridge {
	/** @var array<int,array{0:string,1:string}> */
	public array $commands = [];

	public function __construct() {
		parent::__construct('/bin/false', '/bin/false', '/tmp/config', '/tmp');
	}

	public function get_service_status(string $target_label): array {
		return [
			'ok'        => true,
			'installed' => true,
			'running'   => 'still-disabled' !== $target_label,
		];
	}

	public function run_service_command(string $command, string $target_label): array {
		$this->commands[] = [$command, $target_label];
		return [
			'ok'        => true,
			'exit_code' => 0,
			'output'    => '',
		];
	}
}

$test_root = sys_get_temp_dir() . '/wp-code-mirror-reconcile-' . bin2hex(random_bytes(4));
mkdir($test_root, 0777, true);
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

function target(string $label, array $plugins, bool $active = true, bool $present = true): array {
	global $test_root;
	$site_path = $test_root . '/' . $label;
	if ($present) {
		@mkdir($site_path . '/wp-content/themes', 0777, true);
		@mkdir($site_path . '/wp-content/plugins', 0777, true);
	}
	return [
		'label'      => $label,
		'site_path'  => $site_path,
		'active'     => $active,
		'themes'     => [],
		'plugins'    => $plugins,
		'mu_plugins' => [],
	];
}

$old_config = [
	'source_site'    => '/tmp/source',
	'rsync_excludes' => ['.git/'],
	'targets'        => [
		target('unchanged', ['alpha']),
		target('changed', ['alpha']),
		target('disabled', ['alpha']),
		target('still-disabled', ['alpha'], false),
		target('vanished', ['alpha'], true, false),
		target('removed', ['alpha']),
	],
];

$new_config = [
	'source_site'    => '/tmp/source',
	'rsync_excludes' => ['.git/'],
	'targets'        => [
		target('unchanged', ['alpha']),
		target('changed', ['alpha', 'beta']),
		target('disabled', ['alpha'], false),
		target('still-disabled', ['alpha'], false),
		target('vanished', ['alpha'], true, false),
	],
];

$bridge = new WP_Code_Mirror_Recording_Bridge();
$repository = new WP_Code_Mirror_Config_Repository('/tmp/config');
$admin = new WP_Code_Mirror_Admin_Page($repository, $bridge, '/tmp/plugin.php');
$method = new ReflectionMethod($admin, 'reconcile_services');
$method->invoke($admin, $old_config, $new_config);

$expected = [
	['restart', 'changed'],
	['uninstall', 'disabled'],
	['uninstall', 'still-disabled'],
	['uninstall', 'vanished'],
	['uninstall', 'removed'],
];

if ($bridge->commands !== $expected) {
	throw new RuntimeException('Expected only affected services to restart/stop: ' . json_encode($bridge->commands));
}

echo "PASS: config save reconciles only affected services\n";
