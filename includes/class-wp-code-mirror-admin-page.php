<?php

declare(strict_types=1);

class WP_Code_Mirror_Admin_Page {
	private const MENU_SLUG = 'wp-code-mirror';

	/** @var WP_Code_Mirror_Config_Repository */
	private $repository;

	/** @var WP_Code_Mirror_Host_Bridge */
	private $bridge;

	/** @var string */
	private $plugin_file;

	public function __construct( WP_Code_Mirror_Config_Repository $repository, WP_Code_Mirror_Host_Bridge $bridge, string $plugin_file ) {
		$this->repository  = $repository;
		$this->bridge      = $bridge;
		$this->plugin_file = $plugin_file;
	}

	public function register(): void {
		add_action( 'admin_menu', [ $this, 'register_menu' ] );
		add_action( 'admin_enqueue_scripts', [ $this, 'enqueue_assets' ] );
		add_action( 'admin_post_wp_code_mirror_save_config', [ $this, 'handle_save_config' ] );
		add_action( 'admin_post_wp_code_mirror_target_action', [ $this, 'handle_target_action' ] );
	}

	public function register_menu(): void {
		add_management_page(
			'Code Mirror',
			'WP Code Mirror',
			'manage_options',
			self::MENU_SLUG,
			[ $this, 'render_page' ]
		);
	}

	public function enqueue_assets( string $hook ): void {
		if ( 'tools_page_' . self::MENU_SLUG !== $hook ) {
			return;
		}

		wp_enqueue_style(
			'wp-code-mirror',
			plugins_url( 'assets/admin.css', $this->plugin_file ),
			[],
			'0.1.0'
		);

		wp_enqueue_script(
			'wp-code-mirror',
			plugins_url( 'assets/admin.js', $this->plugin_file ),
			[],
			'0.1.0',
			true
		);
	}

	public function render_page(): void {
		if ( ! current_user_can( 'manage_options' ) ) {
			wp_die( esc_html__( 'You are not allowed to access this page.', 'wp-code-mirror' ) );
		}

		$config   = $this->repository->load();
		$targets  = $config['targets'];
		$message  = isset( $_GET['pcm_notice'] ) ? sanitize_text_field( wp_unslash( $_GET['pcm_notice'] ) ) : '';
		$level    = isset( $_GET['pcm_level'] ) ? sanitize_text_field( wp_unslash( $_GET['pcm_level'] ) ) : 'success';
		$logs_map = [];

		?>
		<div class="wrap wp-code-mirror-admin">
			<h1>WP Code Mirror</h1>
			<p>Test across many WordPress sites from one working codebase. Manage the shared config, check watcher health, and control the local mirror service from here.</p>
			<?php if ( '' !== $message ) : ?>
				<div class="notice notice-<?php echo esc_attr( 'error' === $level ? 'error' : 'success' ); ?> is-dismissible">
					<p><?php echo esc_html( $message ); ?></p>
				</div>
			<?php endif; ?>

			<div class="wp-code-mirror-grid">
				<div class="wp-code-mirror-panel">
					<h2>Config</h2>
					<p><code><?php echo esc_html( $this->repository->get_config_path() ); ?></code></p>
					<form method="post" action="<?php echo esc_url( admin_url( 'admin-post.php' ) ); ?>">
						<?php wp_nonce_field( 'wp_code_mirror_save_config' ); ?>
						<input type="hidden" name="action" value="wp_code_mirror_save_config">

						<label class="wp-code-mirror-field">
							<span>Source Site</span>
							<input type="text" name="source_site" value="<?php echo esc_attr( (string) $config['source_site'] ); ?>" class="regular-text code">
						</label>

						<label class="wp-code-mirror-field">
							<span>Rsync Excludes</span>
							<textarea name="rsync_excludes" rows="5" class="large-text code"><?php echo esc_textarea( implode( "\n", (array) $config['rsync_excludes'] ) ); ?></textarea>
						</label>

						<div class="wp-code-mirror-targets" data-targets-root>
							<div class="wp-code-mirror-targets-header">
								<h3>Targets</h3>
								<button type="button" class="button" data-add-target>Add Target</button>
							</div>
							<?php
							if ( empty( $targets ) ) {
								$targets = [
									[
										'label'     => '',
										'site_path' => '',
										'themes'    => [],
										'plugins'   => [],
									],
								];
							}

							foreach ( $targets as $index => $target ) {
								$this->render_target_editor( (int) $index, (array) $target );
							}
							?>
						</div>

						<script type="text/template" id="wp-code-mirror-target-template">
							<?php $this->render_target_editor( '__INDEX__', [ 'label' => '', 'site_path' => '', 'themes' => [], 'plugins' => [] ] ); ?>
						</script>

						<p>
							<button type="submit" class="button button-primary">Save Config</button>
						</p>
					</form>
				</div>

				<div class="wp-code-mirror-panel">
					<h2>Targets</h2>
					<?php foreach ( (array) $config['targets'] as $target ) : ?>
						<?php
						$label          = (string) ( $target['label'] ?? '' );
						$service_status = '' !== $label ? $this->bridge->get_service_status( $label ) : [ 'ok' => false, 'message' => 'Missing target label.' ];
						$sync_status    = '' !== $label ? $this->bridge->get_sync_status( $label ) : [ 'ok' => false, 'message' => 'Missing target label.' ];
						$logs           = '' !== $label ? $this->bridge->get_logs( $label ) : [ 'stdout' => '', 'stderr' => '' ];
						?>
						<div class="wp-code-mirror-target-card">
							<div class="wp-code-mirror-target-card__header">
								<div>
									<h3><?php echo esc_html( $label ); ?></h3>
									<p><code><?php echo esc_html( (string) ( $target['site_path'] ?? '' ) ); ?></code></p>
								</div>
								<div class="wp-code-mirror-badges">
									<?php $this->render_status_badge( $service_status, $sync_status ); ?>
								</div>
							</div>

							<div class="wp-code-mirror-meta">
								<?php $this->render_target_meta( $service_status, $sync_status ); ?>
							</div>

							<div class="wp-code-mirror-actions">
								<?php $this->render_action_form( 'install', 'Install Watcher', $label, 'secondary' ); ?>
								<?php $this->render_action_form( 'sync', 'Sync Now', $label, 'primary' ); ?>
								<?php $this->render_action_form( 'start', 'Start', $label, 'secondary' ); ?>
								<?php $this->render_action_form( 'stop', 'Stop', $label, 'secondary' ); ?>
								<?php $this->render_action_form( 'restart', 'Restart', $label, 'secondary' ); ?>
							</div>

							<div class="wp-code-mirror-logs">
								<div>
									<h4>Watcher Log</h4>
									<pre><?php echo esc_html( '' !== $logs['stdout'] ? $logs['stdout'] : 'No log output yet.' ); ?></pre>
								</div>
								<div>
									<h4>Watcher Errors</h4>
									<pre><?php echo esc_html( '' !== $logs['stderr'] ? $logs['stderr'] : 'No error output.' ); ?></pre>
								</div>
							</div>
						</div>
					<?php endforeach; ?>
				</div>
			</div>
		</div>
		<?php
	}

	public function handle_save_config(): void {
		$this->assert_manage_options();
		check_admin_referer( 'wp_code_mirror_save_config' );

		$input = [
			'source_site'    => isset( $_POST['source_site'] ) ? wp_unslash( $_POST['source_site'] ) : '',
			'rsync_excludes' => isset( $_POST['rsync_excludes'] ) ? wp_unslash( $_POST['rsync_excludes'] ) : '',
			'targets'        => isset( $_POST['targets'] ) ? wp_unslash( $_POST['targets'] ) : [],
		];

		try {
			$config = $this->repository->normalize_from_input( $input );
			$this->repository->save( $config );

			foreach ( (array) $config['targets'] as $target ) {
				if ( empty( $target['label'] ) ) {
					continue;
				}

				$status = $this->bridge->get_service_status( (string) $target['label'] );
				if ( ! empty( $status['installed'] ) ) {
					$this->bridge->run_service_command( 'restart', (string) $target['label'] );
				}
			}

			$this->redirect_with_notice( 'Config saved.', 'success' );
		} catch ( Throwable $exception ) {
			$this->redirect_with_notice( $exception->getMessage(), 'error' );
		}
	}

	public function handle_target_action(): void {
		$this->assert_manage_options();
		check_admin_referer( 'wp_code_mirror_target_action' );

		$command = isset( $_POST['command'] ) ? sanitize_text_field( wp_unslash( $_POST['command'] ) ) : '';
		$target  = isset( $_POST['target_label'] ) ? sanitize_text_field( wp_unslash( $_POST['target_label'] ) ) : '';

		if ( '' === $target || '' === $command ) {
			$this->redirect_with_notice( 'Target action is missing required data.', 'error' );
		}

		if ( 'sync' === $command ) {
			$result = $this->bridge->sync( $target );
		} else {
			$result = $this->bridge->run_service_command( $command, $target );
		}

		if ( $result['ok'] ) {
			$this->redirect_with_notice( sprintf( '%s completed for %s.', ucfirst( $command ), $target ), 'success' );
		}

		$this->redirect_with_notice( $result['output'], 'error' );
	}

	/**
	 * @param int|string $index
	 * @param array<string,mixed> $target
	 */
	private function render_target_editor( $index, array $target ): void {
		?>
		<div class="wp-code-mirror-target-editor" data-target>
			<div class="wp-code-mirror-target-editor__header">
				<h4>Target</h4>
				<button type="button" class="button-link-delete" data-remove-target>Remove</button>
			</div>

			<label class="wp-code-mirror-field">
				<span>Label</span>
				<input type="text" name="targets[<?php echo esc_attr( (string) $index ); ?>][label]" value="<?php echo esc_attr( (string) ( $target['label'] ?? '' ) ); ?>" class="regular-text code">
			</label>

			<label class="wp-code-mirror-field">
				<span>Site Path</span>
				<input type="text" name="targets[<?php echo esc_attr( (string) $index ); ?>][site_path]" value="<?php echo esc_attr( (string) ( $target['site_path'] ?? '' ) ); ?>" class="large-text code">
			</label>

			<label class="wp-code-mirror-field">
				<span>Themes</span>
				<textarea name="targets[<?php echo esc_attr( (string) $index ); ?>][themes]" rows="4" class="large-text code"><?php echo esc_textarea( implode( "\n", (array) ( $target['themes'] ?? [] ) ) ); ?></textarea>
			</label>

			<label class="wp-code-mirror-field">
				<span>Plugins</span>
				<textarea name="targets[<?php echo esc_attr( (string) $index ); ?>][plugins]" rows="5" class="large-text code"><?php echo esc_textarea( implode( "\n", (array) ( $target['plugins'] ?? [] ) ) ); ?></textarea>
			</label>
		</div>
		<?php
	}

	/**
	 * @param array<string,mixed> $service_status
	 * @param array<string,mixed> $sync_status
	 */
	private function render_status_badge( array $service_status, array $sync_status ): void {
		if ( ! empty( $service_status['running'] ) ) {
			echo '<span class="wp-code-mirror-badge is-running">Watcher Running</span>';
		} elseif ( ! empty( $service_status['installed'] ) ) {
			echo '<span class="wp-code-mirror-badge is-installed">Installed</span>';
		} else {
			echo '<span class="wp-code-mirror-badge is-stopped">Not Installed</span>';
		}

		if ( ! empty( $sync_status['targets'][0]['state'] ) ) {
			$state = (string) $sync_status['targets'][0]['state'];
			printf(
				'<span class="wp-code-mirror-badge %1$s">%2$s</span>',
				esc_attr( 'CLEAN' === $state ? 'is-clean' : 'is-pending' ),
				esc_html( $state )
			);
		}
	}

	/**
	 * @param array<string,mixed> $service_status
	 * @param array<string,mixed> $sync_status
	 */
	private function render_target_meta( array $service_status, array $sync_status ): void {
		$items = [];

		if ( ! empty( $service_status['service_label'] ) ) {
			$items['Service'] = (string) $service_status['service_label'];
		}

		if ( ! empty( $service_status['pid'] ) ) {
			$items['PID'] = (string) $service_status['pid'];
		}

		if ( ! empty( $service_status['status_file'] ) ) {
			$items['Status File'] = (string) $service_status['status_file'];
		}

		if ( ! empty( $service_status['stdout_log'] ) ) {
			$items['Log File'] = (string) $service_status['stdout_log'];
		}

		if ( ! empty( $service_status['sync_status']['last_sync_at'] ) ) {
			$items['Last Sync'] = (string) $service_status['sync_status']['last_sync_at'];
		} elseif ( ! empty( $sync_status['updated_at'] ) ) {
			$items['Last Checked'] = (string) $sync_status['updated_at'];
		}

		if ( empty( $items ) && ! empty( $service_status['message'] ) ) {
			$items['Status'] = (string) $service_status['message'];
		}

		echo '<dl>';
		foreach ( $items as $label => $value ) {
			printf( '<dt>%s</dt><dd><code>%s</code></dd>', esc_html( $label ), esc_html( $value ) );
		}
		echo '</dl>';
	}

	private function render_action_form( string $command, string $label, string $target_label, string $button_class ): void {
		?>
		<form method="post" action="<?php echo esc_url( admin_url( 'admin-post.php' ) ); ?>">
			<?php wp_nonce_field( 'wp_code_mirror_target_action' ); ?>
			<input type="hidden" name="action" value="wp_code_mirror_target_action">
			<input type="hidden" name="command" value="<?php echo esc_attr( $command ); ?>">
			<input type="hidden" name="target_label" value="<?php echo esc_attr( $target_label ); ?>">
			<button type="submit" class="button button-<?php echo esc_attr( $button_class ); ?>"><?php echo esc_html( $label ); ?></button>
		</form>
		<?php
	}

	private function assert_manage_options(): void {
		if ( ! current_user_can( 'manage_options' ) ) {
			wp_die( esc_html__( 'You are not allowed to perform this action.', 'wp-code-mirror' ) );
		}
	}

	private function redirect_with_notice( string $message, string $level ): void {
		$url = add_query_arg(
			[
				'page'       => self::MENU_SLUG,
				'pcm_notice' => $message,
				'pcm_level'  => $level,
			],
			admin_url( 'tools.php' )
		);

		wp_safe_redirect( $url );
		exit;
	}
}
