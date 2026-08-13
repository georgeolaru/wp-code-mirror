<?php

declare(strict_types=1);

ini_set('memory_limit', '16M');

$plugin_dir = dirname(__DIR__);
$class_file = $argv[1] ?? $plugin_dir . '/includes/class-wp-code-mirror-host-bridge.php';
require_once $class_file;

$temp_dir = sys_get_temp_dir() . '/wp-code-mirror-tail-' . bin2hex(random_bytes(4));
if (! mkdir($temp_dir, 0777, true) && ! is_dir($temp_dir)) {
	throw new RuntimeException('Failed to create temp directory.');
}

try {
	$log_path = $temp_dir . '/wp-code-mirror-large.log';
	$handle = fopen($log_path, 'wb');
	if (false === $handle) {
		throw new RuntimeException('Failed to create sparse log.');
	}

	ftruncate($handle, 256 * 1024 * 1024);
	fseek($handle, 0, SEEK_END);
	fwrite($handle, "\nolder tail line\nnewest tail line\n");
	fclose($handle);

	$bridge = new WP_Code_Mirror_Host_Bridge('/bin/false', '/bin/false', '/tmp/config', $temp_dir);
	$logs = $bridge->get_logs('large', 2);

	if ($logs['stdout'] !== "older tail line\nnewest tail line") {
		throw new RuntimeException('Expected only the final two lines from the sparse 256 MB log.');
	}

	if (memory_get_peak_usage(true) > 12 * 1024 * 1024) {
		throw new RuntimeException('Tail reader used too much memory.');
	}

	echo "PASS: host bridge reads a huge log tail with bounded memory\n";
} finally {
	@unlink($temp_dir . '/wp-code-mirror-large.log');
	@rmdir($temp_dir);
}
