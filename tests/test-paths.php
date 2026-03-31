<?php

declare(strict_types=1);

$repo_root = dirname(__DIR__);
$data_root = sys_get_temp_dir() . '/wp-code-mirror-site-data';

require_once $repo_root . '/includes/class-wp-code-mirror-paths.php';

$paths = new WP_Code_Mirror_Paths($repo_root, $data_root);

if ($paths->plugin_root() !== $repo_root) {
	throw new RuntimeException('Expected plugin root to match repo root.');
}

if ($paths->scripts_dir() !== $repo_root . '/scripts') {
	throw new RuntimeException('Expected scripts dir inside plugin root.');
}

if ($paths->config_path() !== $data_root . '/config/wp-code-mirror.config.json') {
	throw new RuntimeException('Expected config path inside site data root.');
}

if ($paths->tmp_dir() !== $data_root . '/tmp') {
	throw new RuntimeException('Expected tmp dir inside site data root.');
}

$derived_paths = new WP_Code_Mirror_Paths('/tmp/example-site/wp-content/plugins/wp-code-mirror');

if ($derived_paths->data_root() !== '/tmp/example-site/wp-content/uploads/wp-code-mirror') {
	throw new RuntimeException('Expected default data root to resolve next to wp-content/uploads.');
}

echo "PASS: paths\n";
