<?php

declare(strict_types=1);

class WP_Code_Mirror_Paths {
	/** @var string */
	private $plugin_root;

	/** @var string */
	private $data_root;

	public function __construct( string $plugin_root, ?string $data_root = null ) {
		$this->plugin_root = rtrim( $plugin_root, '/\\' );
		$this->data_root   = null !== $data_root ? rtrim( $data_root, '/\\' ) : $this->default_data_root();
	}

	public function plugin_root(): string {
		return $this->plugin_root;
	}

	public function scripts_dir(): string {
		return $this->plugin_root . '/scripts';
	}

	public function data_root(): string {
		return $this->data_root;
	}

	public function config_dir(): string {
		return $this->data_root . '/config';
	}

	public function config_path(): string {
		return $this->config_dir() . '/wp-code-mirror.config.json';
	}

	public function tmp_dir(): string {
		return $this->data_root . '/tmp';
	}

	public function legacy_config_path(): string {
		return $this->plugin_root . '/config/wp-code-mirror.config.json';
	}

	private function default_data_root(): string {
		if ( preg_match( '#^(.*)/wp-content/plugins/[^/]+$#', $this->plugin_root, $matches ) ) {
			return $matches[1] . '/wp-content/uploads/wp-code-mirror';
		}

		return $this->plugin_root;
	}
}
