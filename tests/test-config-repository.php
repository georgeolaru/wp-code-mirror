<?php

declare(strict_types=1);

$plugin_dir = dirname(__DIR__);

require_once $plugin_dir . '/includes/class-wp-code-mirror-config-repository.php';

$temp_dir = sys_get_temp_dir() . '/wp-code-mirror-' . bin2hex(random_bytes(4));
if (! mkdir($temp_dir, 0777, true) && ! is_dir($temp_dir)) {
	throw new RuntimeException('Failed to create temp dir');
}

$config_path = $temp_dir . '/wp-code-mirror.config.json';

$seed = [
	'source_site'    => '/tmp/source',
	'targets'        => [
		[
			'label'      => 'site-a',
			'site_path'  => '/tmp/site-a',
			'themes'     => ['anima'],
			'plugins'    => ['pixelgrade-care'],
			'mu_plugins' => ['example-loader.php'],
		],
	],
	'rsync_excludes' => ['.DS_Store'],
];

file_put_contents($config_path, json_encode($seed, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES));

$repository = new WP_Code_Mirror_Config_Repository($config_path);
$loaded = $repository->load();

if ($loaded['source_site'] !== '/tmp/source') {
	throw new RuntimeException('Expected source_site to load from JSON');
}

if ($loaded['targets'][0]['mu_plugins'][0] !== 'example-loader.php') {
	throw new RuntimeException('Expected mu_plugins to load from JSON');
}

$normalized = $repository->normalize_from_input(
	[
		'source_site'    => '/tmp/source-updated',
		'rsync_excludes' => ".DS_Store\n.git/\n",
		'targets'        => [
			[
				'label'      => 'site-b',
				'site_path'  => '/tmp/site-b',
				'themes'     => "anima\n",
				'plugins'    => "pixelgrade-care\nnova-blocks\nstyle-manager\n",
				'mu_plugins' => "type-system-transfusion.php\ntype-system-transfusion\n",
			],
		],
	]
);

if ($normalized['targets'][0]['plugins'][2] !== 'style-manager') {
	throw new RuntimeException('Expected plugin lines to normalize into arrays');
}

if ($normalized['targets'][0]['mu_plugins'][1] !== 'type-system-transfusion') {
	throw new RuntimeException('Expected mu_plugins lines to normalize into arrays');
}

$repository->save($normalized);

$saved = json_decode((string) file_get_contents($config_path), true, 512, JSON_THROW_ON_ERROR);

if ($saved['source_site'] !== '/tmp/source-updated') {
	throw new RuntimeException('Expected saved source_site to update');
}

if ($saved['targets'][0]['themes'][0] !== 'anima') {
	throw new RuntimeException('Expected themes to persist after save');
}

if ($saved['targets'][0]['mu_plugins'][0] !== 'type-system-transfusion.php') {
	throw new RuntimeException('Expected mu_plugins to persist after save');
}

echo "PASS: config repository\n";
