<?php

declare(strict_types=1);

$repo_root = dirname(__DIR__);

require_once $repo_root . '/includes/class-wp-code-mirror-paths.php';

$paths = new WP_Code_Mirror_Paths($repo_root);

if ($paths->plugin_root() !== $repo_root) {
	throw new RuntimeException('Expected plugin root to match repo root.');
}

if ($paths->scripts_dir() !== $repo_root . '/scripts') {
	throw new RuntimeException('Expected scripts dir inside plugin root.');
}

if ($paths->config_path() !== $repo_root . '/config/wp-code-mirror.config.json') {
	throw new RuntimeException('Expected config path inside plugin root.');
}

if ($paths->tmp_dir() !== $repo_root . '/tmp') {
	throw new RuntimeException('Expected tmp dir inside plugin root.');
}

echo "PASS: paths\n";
