<?php

declare(strict_types=1);

class WP_Code_Mirror_Paths {
	/** @var string */
	private $plugin_root;

	public function __construct( string $plugin_root ) {
		$this->plugin_root = rtrim( $plugin_root, '/\\' );
	}

	public function plugin_root(): string {
		return $this->plugin_root;
	}

	public function scripts_dir(): string {
		return $this->plugin_root . '/scripts';
	}

	public function config_dir(): string {
		return $this->plugin_root . '/config';
	}

	public function config_path(): string {
		return $this->config_dir() . '/wp-code-mirror.config.json';
	}

	public function tmp_dir(): string {
		return $this->plugin_root . '/tmp';
	}
}
