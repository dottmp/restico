.PHONY: install-cli help systemd-install systemd-status systemd-force

install-cli:          # Install restico command to ~/.local/bin
	mkdir -p ~/.local/bin
	rm -f ~/.local/bin/restico
	cp restico.sh ~/.local/bin/restico
	chmod +x ~/.local/bin/restico
	@echo "Make sure ~/.local/bin is in your PATH"

systemd-install:      # Enable the systemd timers
	mkdir -p ~/.config/systemd/user
	cp systemd/* ~/.config/systemd/user/
	systemctl --user daemon-reload
	systemctl --user enable --now restico-backup.timer
	systemctl --user enable --now restico-prune.timer
	systemctl --user enable --now restico-verify.timer
	@echo "Don't forget: loginctl enable-linger $$(whoami)"

systemd-status:       # Check timer and service status
	@echo "=== Backup ==="
	systemctl --user status restico-backup.timer
	@echo "---"
	systemctl --user list-timers restico-backup.timer
	@echo "=== Prune ==="
	systemctl --user status restico-prune.timer || true
	@echo "---"
	systemctl --user list-timers restico-prune.timer || true
	@echo "=== Verify ==="
	systemctl --user status restico-verify.timer || true
	@echo "---"
	systemctl --user list-timers restico-verify.timer || true

systemd-force:        # Trigger backup service immediately
	@echo "Triggering restico-backup.service"
	systemctl --user start restico-backup.service

help:                 # Show available commands
	@grep -E '^[a-zA-Z_-]+:.*#' Makefile | sed 's/:.*#/:/'
