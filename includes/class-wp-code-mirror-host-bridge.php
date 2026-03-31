<?php

declare(strict_types=1);

class WP_Code_Mirror_Host_Bridge {
	/** @var string */
	private $sync_script_path;

	/** @var string */
	private $service_script_path;

	/** @var string */
	private $config_path;

	/** @var string */
	private $tmp_dir;

	public function __construct( string $sync_script_path, string $service_script_path, string $config_path, string $tmp_dir ) {
		$this->sync_script_path    = $sync_script_path;
		$this->service_script_path = $service_script_path;
		$this->config_path         = $config_path;
		$this->tmp_dir             = $tmp_dir;
	}

	/**
	 * @return array{ok:bool,exit_code:int,output:string}
	 */
	public function sync( string $target_label ): array {
		return $this->run(
			[
				'/bin/bash',
				$this->sync_script_path,
				'sync',
				'--config',
				$this->config_path,
				'--target',
				$target_label,
				'--status-file',
				$this->status_file_path( $target_label ),
			]
		);
	}

	/**
	 * @return array<string,mixed>
	 */
	public function get_sync_status( string $target_label ): array {
		$file_status = $this->read_status_file( $target_label );
		if ( null !== $file_status ) {
			$file_status['ok'] = true;
			return $file_status;
		}

		$result = $this->run(
			[
				'/bin/bash',
				$this->sync_script_path,
				'status',
				'--config',
				$this->config_path,
				'--target',
				$target_label,
				'--json',
				'--status-file',
				$this->status_file_path( $target_label ),
			]
		);

		if ( ! $result['ok'] ) {
			return [
				'ok'      => false,
				'message' => $result['output'],
			];
		}

		$decoded = json_decode( $result['output'], true );
		if ( ! is_array( $decoded ) ) {
			return [
				'ok'      => false,
				'message' => 'Invalid sync status JSON.',
			];
		}

		$decoded['ok'] = true;
		return $decoded;
	}

	/**
	 * @return array<string,mixed>
	 */
	public function get_service_status( string $target_label ): array {
		$result = $this->run(
			[
				'/bin/bash',
				$this->service_script_path,
				'status',
				'--config',
				$this->config_path,
				'--runtime-dir',
				$this->tmp_dir,
				'--target',
				$target_label,
				'--json',
			]
		);

		if ( ! $result['ok'] ) {
			return $this->fallback_service_status( $target_label, $result['output'] );
		}

		$decoded = json_decode( $result['output'], true );
		if ( ! is_array( $decoded ) ) {
			return $this->fallback_service_status( $target_label, 'Invalid service status JSON.' );
		}

		$decoded['ok'] = true;
		return $decoded;
	}

	/**
	 * @return array{ok:bool,exit_code:int,output:string}
	 */
	public function run_service_command( string $command, string $target_label ): array {
		$allowed = [ 'install', 'start', 'stop', 'restart', 'uninstall' ];
		if ( ! in_array( $command, $allowed, true ) ) {
			return [
				'ok'        => false,
				'exit_code' => 1,
				'output'    => 'Unsupported service command.',
			];
		}

		return $this->run(
			[
				'/bin/bash',
				$this->service_script_path,
				$command,
				'--config',
				$this->config_path,
				'--runtime-dir',
				$this->tmp_dir,
				'--target',
				$target_label,
			]
		);
	}

	/**
	 * @return array{stdout:string,stderr:string}
	 */
	public function get_logs( string $target_label, int $line_limit = 40 ): array {
		return [
			'stdout' => $this->tail_file( $this->stdout_log_path( $target_label ), $line_limit ),
			'stderr' => $this->tail_file( $this->stderr_log_path( $target_label ), $line_limit ),
		];
	}

	public function status_file_path( string $target_label ): string {
		return $this->tmp_dir . '/wp-code-mirror-' . $this->sanitize_label( $target_label ) . '-status.json';
	}

	private function plist_path( string $target_label ): string {
		return $this->detect_user_home_dir() . '/Library/LaunchAgents/com.wp-code-mirror.sync.' . $this->sanitize_label( $target_label ) . '.plist';
	}

	private function stdout_log_path( string $target_label ): string {
		return $this->tmp_dir . '/wp-code-mirror-' . $this->sanitize_label( $target_label ) . '.log';
	}

	private function stderr_log_path( string $target_label ): string {
		return $this->tmp_dir . '/wp-code-mirror-' . $this->sanitize_label( $target_label ) . '.error.log';
	}

	private function sanitize_label( string $target_label ): string {
		return (string) preg_replace( '/[^A-Za-z0-9._-]+/', '-', $target_label );
	}

	/**
	 * @return array<string,mixed>|null
	 */
	private function read_status_file( string $target_label ): ?array {
		$path = $this->status_file_path( $target_label );
		if ( ! file_exists( $path ) ) {
			return null;
		}

		$contents = file_get_contents( $path );
		if ( false === $contents || '' === trim( $contents ) ) {
			return null;
		}

		$decoded = json_decode( $contents, true );
		return is_array( $decoded ) ? $decoded : null;
	}

	/**
	 * @return array<string,mixed>
	 */
	private function fallback_service_status( string $target_label, string $message ): array {
		$plist_path   = $this->plist_path( $target_label );
		$status_path  = $this->status_file_path( $target_label );
		$sync_status  = $this->read_status_file( $target_label );
		$installed    = file_exists( $plist_path ) || null !== $sync_status;
		$running      = false;
		$current_time = time();

		if ( null !== $sync_status ) {
			$updated_at = isset( $sync_status['updated_at'] ) ? strtotime( (string) $sync_status['updated_at'] ) : false;
			if ( false !== $updated_at && ( $current_time - $updated_at ) <= 10 ) {
				$running = true;
			}
		}

		return [
			'ok'          => true,
			'target_label'=> $target_label,
			'service_label' => 'com.wp-code-mirror.sync.' . $this->sanitize_label( $target_label ),
			'installed'   => $installed,
			'running'     => $installed && $running,
			'pid'         => null,
			'state'       => $installed ? ( $running ? 'running' : 'installed' ) : 'stopped',
			'plist_path'  => $plist_path,
			'status_file' => $status_path,
			'stdout_log'  => $this->stdout_log_path( $target_label ),
			'stderr_log'  => $this->stderr_log_path( $target_label ),
			'sync_status' => $sync_status,
			'message'     => '' !== $message ? $message : 'Using filesystem fallback status.',
		];
	}

	private function detect_user_home_dir(): string {
		if ( ! empty( $_SERVER['HOME'] ) ) {
			return (string) $_SERVER['HOME'];
		}

		$abspath = defined( 'ABSPATH' ) ? (string) ABSPATH : '';
		if ( preg_match( '#^(/Users/[^/]+)#', $abspath, $matches ) ) {
			return $matches[1];
		}

		if ( preg_match( '#^(/home/[^/]+)#', $abspath, $matches ) ) {
			return $matches[1];
		}

		return '/Users/' . get_current_user();
	}

	/**
	 * @param array<int,string> $command
	 * @return array{ok:bool,exit_code:int,output:string}
	 */
	private function run( array $command ): array {
		$escaped = array_map( 'escapeshellarg', $command );
		$command_string = implode( ' ', $escaped ) . ' 2>&1';

		$output = [];
		$exit_code = 0;
		exec( $command_string, $output, $exit_code );

		return [
			'ok'        => 0 === $exit_code,
			'exit_code' => $exit_code,
			'output'    => trim( implode( "\n", $output ) ),
		];
	}

	private function tail_file( string $path, int $line_limit ): string {
		if ( ! file_exists( $path ) ) {
			return '';
		}

		$contents = file( $path, FILE_IGNORE_NEW_LINES );
		if ( false === $contents ) {
			return '';
		}

		return implode( "\n", array_slice( $contents, -1 * $line_limit ) );
	}
}
