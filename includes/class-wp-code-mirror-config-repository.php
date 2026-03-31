<?php

declare(strict_types=1);

class WP_Code_Mirror_Config_Repository {
	/** @var string */
	private $config_path;

	public function __construct( string $config_path ) {
		$this->config_path = $config_path;
	}

	/**
	 * @return array<string,mixed>
	 */
	public function load(): array {
		if ( ! file_exists( $this->config_path ) ) {
			return $this->default_config();
		}

		$contents = file_get_contents( $this->config_path );
		if ( false === $contents || '' === trim( $contents ) ) {
			return $this->default_config();
		}

		$decoded = json_decode( $contents, true );
		if ( ! is_array( $decoded ) ) {
			return $this->default_config();
		}

		return $this->normalize_loaded_config( $decoded );
	}

	/**
	 * @param array<string,mixed> $input
	 * @return array<string,mixed>
	 */
	public function normalize_from_input( array $input ): array {
		$targets = [];
		$raw_targets = $input['targets'] ?? [];

		if ( is_array( $raw_targets ) ) {
			foreach ( $raw_targets as $raw_target ) {
				if ( ! is_array( $raw_target ) ) {
					continue;
				}

				$target = [
					'label'     => $this->normalize_scalar( $raw_target['label'] ?? '' ),
					'site_path' => $this->normalize_scalar( $raw_target['site_path'] ?? '' ),
					'themes'    => $this->normalize_line_list( $raw_target['themes'] ?? [] ),
					'plugins'   => $this->normalize_line_list( $raw_target['plugins'] ?? [] ),
				];

				if ( '' === $target['label'] && '' === $target['site_path'] && [] === $target['themes'] && [] === $target['plugins'] ) {
					continue;
				}

				$targets[] = $target;
			}
		}

		return [
			'source_site'    => $this->normalize_scalar( $input['source_site'] ?? '' ),
			'targets'        => $targets,
			'rsync_excludes' => $this->normalize_line_list( $input['rsync_excludes'] ?? [] ),
		];
	}

	/**
	 * @param array<string,mixed> $config
	 */
	public function save( array $config ): void {
		$normalized = $this->normalize_loaded_config( $config );
		$directory  = dirname( $this->config_path );

		if ( ! is_dir( $directory ) ) {
			mkdir( $directory, 0775, true );
		}

		$encoded = json_encode( $normalized, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES );
		if ( false === $encoded ) {
			throw new RuntimeException( 'Failed to encode code mirror config.' );
		}

		file_put_contents( $this->config_path, $encoded . PHP_EOL );
	}

	public function get_config_path(): string {
		return $this->config_path;
	}

	/**
	 * @param array<string,mixed> $config
	 * @return array<string,mixed>
	 */
	private function normalize_loaded_config( array $config ): array {
		return [
			'source_site'    => $this->normalize_scalar( $config['source_site'] ?? '' ),
			'targets'        => $this->normalize_targets( $config['targets'] ?? [] ),
			'rsync_excludes' => $this->normalize_line_list( $config['rsync_excludes'] ?? [] ),
		];
	}

	/**
	 * @param mixed $value
	 */
	private function normalize_scalar( $value ): string {
		if ( is_string( $value ) ) {
			return trim( $value );
		}

		if ( is_numeric( $value ) ) {
			return trim( (string) $value );
		}

		return '';
	}

	/**
	 * @param mixed $value
	 * @return array<int,string>
	 */
	private function normalize_line_list( $value ): array {
		$items = [];

		if ( is_string( $value ) ) {
			$items = preg_split( '/[\r\n,]+/', $value ) ?: [];
		} elseif ( is_array( $value ) ) {
			foreach ( $value as $entry ) {
				if ( is_string( $entry ) || is_numeric( $entry ) ) {
					$items[] = (string) $entry;
				}
			}
		}

		$items = array_map( 'trim', $items );
		$items = array_filter(
			$items,
			static function ( string $item ): bool {
				return '' !== $item;
			}
		);

		return array_values( array_unique( $items ) );
	}

	/**
	 * @param mixed $targets
	 * @return array<int,array<string,mixed>>
	 */
	private function normalize_targets( $targets ): array {
		$normalized = [];

		if ( ! is_array( $targets ) ) {
			return $normalized;
		}

		foreach ( $targets as $target ) {
			if ( ! is_array( $target ) ) {
				continue;
			}

			$normalized[] = [
				'label'     => $this->normalize_scalar( $target['label'] ?? '' ),
				'site_path' => $this->normalize_scalar( $target['site_path'] ?? '' ),
				'themes'    => $this->normalize_line_list( $target['themes'] ?? [] ),
				'plugins'   => $this->normalize_line_list( $target['plugins'] ?? [] ),
			];
		}

		return $normalized;
	}

	/**
	 * @return array<string,mixed>
	 */
	private function default_config(): array {
		return [
			'source_site'    => '',
			'targets'        => [],
			'rsync_excludes' => [
				'.DS_Store',
				'.git/',
				'.github/',
				'.idea/',
				'node_modules/',
			],
		];
	}
}
