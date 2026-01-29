// Toggle Vault - Web UI Application

class ToggleVault {
    constructor() {
        this.files = [];
        this.selectedFile = null;
        this.selectedVersion = null;
        this.versions = [];
        this.currentDiff = null;
        this.diffMode = 'unified'; // 'unified' or 'split'
        
        this.initElements();
        this.initEventListeners();
        this.loadFiles();
    }
    
    initElements() {
        // File tree
        this.fileTree = document.getElementById('file-tree');
        this.fileCount = document.getElementById('file-count');
        this.searchInput = document.getElementById('search');
        this.refreshBtn = document.getElementById('refresh-btn');
        
        // Views
        this.welcomeView = document.getElementById('welcome-view');
        this.fileView = document.getElementById('file-view');
        this.diffView = document.getElementById('diff-view');
        
        // File view elements
        this.filePath = document.getElementById('file-path');
        this.fileStatus = document.getElementById('file-status');
        this.versionsList = document.getElementById('versions-list');
        this.versionDetail = document.getElementById('version-detail');
        
        // Diff view elements
        this.diffTitle = document.getElementById('diff-title');
        this.diffStats = document.getElementById('diff-stats');
        this.diffContent = document.getElementById('diff-content');
        this.closeDiffBtn = document.getElementById('close-diff');
        this.diffModeUnifiedBtn = document.getElementById('diff-mode-unified');
        this.diffModeSplitBtn = document.getElementById('diff-mode-split');
        
        // Modal elements
        this.restoreModal = document.getElementById('restore-modal');
        this.restoreMessage = document.getElementById('restore-message');
        this.restoreConfirmBtn = document.getElementById('restore-confirm');
        this.restoreCancelBtn = document.getElementById('restore-cancel');
    }
    
    initEventListeners() {
        // Search
        this.searchInput.addEventListener('input', () => this.filterFiles());
        
        // Refresh
        this.refreshBtn.addEventListener('click', () => this.loadFiles());
        
        // Close diff
        this.closeDiffBtn.addEventListener('click', () => this.closeDiff());
        
        // Diff mode toggles
        this.diffModeUnifiedBtn.addEventListener('click', () => this.setDiffMode('unified'));
        this.diffModeSplitBtn.addEventListener('click', () => this.setDiffMode('split'));
        
        // Modal
        this.restoreCancelBtn.addEventListener('click', () => this.closeRestoreModal());
    }
    
    setDiffMode(mode) {
        this.diffMode = mode;
        this.diffModeUnifiedBtn.classList.toggle('active', mode === 'unified');
        this.diffModeSplitBtn.classList.toggle('active', mode === 'split');
        
        if (this.currentDiff) {
            this.renderDiff(this.currentDiff);
        }
    }
    
    async loadFiles() {
        this.fileTree.innerHTML = '<div class="loading">Loading files...</div>';
        
        try {
            const response = await fetch('/api/files');
            if (!response.ok) throw new Error('Failed to load files');
            
            this.files = await response.json();
            this.renderFileTree();
        } catch (error) {
            console.error('Error loading files:', error);
            this.fileTree.innerHTML = '<div class="loading">Error loading files</div>';
        }
    }
    
    renderFileTree() {
        const searchTerm = this.searchInput.value.toLowerCase();
        const filteredFiles = this.files.filter(file => 
            file.blob_path.toLowerCase().includes(searchTerm)
        );
        
        this.fileCount.textContent = filteredFiles.length;
        
        if (filteredFiles.length === 0) {
            this.fileTree.innerHTML = '<div class="loading">No files found</div>';
            return;
        }
        
        this.fileTree.innerHTML = filteredFiles.map(file => `
            <div class="file-item ${file.is_deleted ? 'deleted' : ''} ${this.selectedFile?.id === file.id ? 'active' : ''}"
                 data-path="${this.escapeHtml(file.blob_path)}"
                 data-id="${file.id}">
                <svg class="file-icon" viewBox="0 0 16 16" fill="currentColor">
                    <path d="M14 4.5V14a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V2a2 2 0 0 1 2-2h5.5L14 4.5zm-3 0A1.5 1.5 0 0 1 9.5 3V1H4a1 1 0 0 0-1 1v12a1 1 0 0 0 1 1h8a1 1 0 0 0 1-1V4.5h-2z"/>
                </svg>
                <span class="file-name" title="${this.escapeHtml(file.blob_path)}">${this.escapeHtml(file.blob_path)}</span>
                <span class="file-version-count">${file.version_count || 0}</span>
            </div>
        `).join('');
        
        // Add click handlers
        this.fileTree.querySelectorAll('.file-item').forEach(item => {
            item.addEventListener('click', () => {
                const path = item.dataset.path;
                const file = this.files.find(f => f.blob_path === path);
                this.selectFile(file);
            });
        });
    }
    
    filterFiles() {
        this.renderFileTree();
    }
    
    async selectFile(file) {
        this.selectedFile = file;
        this.selectedVersion = null;
        
        // Update UI
        this.renderFileTree();
        this.showFileView();
        
        this.filePath.textContent = file.blob_path;
        this.fileStatus.textContent = file.is_deleted ? 'Deleted' : (file.latest_change_type || 'Active');
        this.fileStatus.className = `status-badge ${file.latest_change_type || ''}`;
        
        // Load versions
        await this.loadVersions(file.blob_path);
    }
    
    async loadVersions(path) {
        this.versionsList.innerHTML = '<div class="loading">Loading versions...</div>';
        this.versionDetail.innerHTML = '<p class="hint">Select a version to view its contents</p>';
        
        try {
            const response = await fetch(`/api/files/${encodeURIComponent(path)}/versions`);
            if (!response.ok) throw new Error('Failed to load versions');
            
            this.versions = await response.json();
            this.renderVersions();
        } catch (error) {
            console.error('Error loading versions:', error);
            this.versionsList.innerHTML = '<div class="loading">Error loading versions</div>';
        }
    }
    
    renderVersions() {
        if (this.versions.length === 0) {
            this.versionsList.innerHTML = '<div class="loading">No versions found</div>';
            return;
        }
        
        this.versionsList.innerHTML = this.versions.map((version, index) => `
            <div class="version-item ${this.selectedVersion?.id === version.id ? 'selected' : ''}"
                 data-id="${version.id}">
                <div class="version-header">
                    <span class="version-type ${version.change_type}">${version.change_type}</span>
                    <span class="version-id">v${version.id}</span>
                </div>
                <div class="version-time">${this.formatDate(version.captured_at)}</div>
                <div class="version-actions">
                    <button class="btn btn-sm btn-secondary view-btn" data-id="${version.id}">View</button>
                    ${index < this.versions.length - 1 ? 
                        `<button class="btn btn-sm btn-secondary diff-btn" data-id="${version.id}" data-prev-id="${this.versions[index + 1].id}">Diff</button>` : 
                        ''}
                    ${version.change_type !== 'deleted' ? 
                        `<button class="btn btn-sm btn-primary restore-btn" data-id="${version.id}">Restore</button>` : 
                        ''}
                </div>
            </div>
        `).join('');
        
        // Add click handlers
        this.versionsList.querySelectorAll('.version-item').forEach(item => {
            item.addEventListener('click', (e) => {
                if (e.target.classList.contains('btn')) return;
                const id = parseInt(item.dataset.id);
                this.selectVersion(id);
            });
        });
        
        this.versionsList.querySelectorAll('.view-btn').forEach(btn => {
            btn.addEventListener('click', () => {
                const id = parseInt(btn.dataset.id);
                this.selectVersion(id);
            });
        });
        
        this.versionsList.querySelectorAll('.diff-btn').forEach(btn => {
            btn.addEventListener('click', () => {
                const id = parseInt(btn.dataset.id);
                const prevId = parseInt(btn.dataset.prevId);
                this.showDiff(prevId, id);
            });
        });
        
        this.versionsList.querySelectorAll('.restore-btn').forEach(btn => {
            btn.addEventListener('click', () => {
                const id = parseInt(btn.dataset.id);
                this.showRestoreModal(id);
            });
        });
    }
    
    async selectVersion(id) {
        const version = this.versions.find(v => v.id === id);
        if (!version) return;
        
        this.selectedVersion = version;
        
        // Update selected state
        this.versionsList.querySelectorAll('.version-item').forEach(item => {
            item.classList.toggle('selected', parseInt(item.dataset.id) === id);
        });
        
        // Show version detail
        this.versionDetail.innerHTML = `
            <div class="version-meta">
                <div class="version-meta-item">
                    <span class="version-meta-label">Version ID:</span>
                    <span>${version.id}</span>
                </div>
                <div class="version-meta-item">
                    <span class="version-meta-label">Change Type:</span>
                    <span class="version-type ${version.change_type}">${version.change_type}</span>
                </div>
                <div class="version-meta-item">
                    <span class="version-meta-label">Captured At:</span>
                    <span>${this.formatDate(version.captured_at)}</span>
                </div>
                <div class="version-meta-item">
                    <span class="version-meta-label">Content Hash:</span>
                    <span style="font-family: monospace; font-size: 0.75rem;">${version.content_hash || 'N/A'}</span>
                </div>
            </div>
            <div class="version-content">${this.escapeHtml(version.content) || '(empty)'}</div>
        `;
    }
    
    async showDiff(v1, v2) {
        try {
            const response = await fetch(`/api/files/${encodeURIComponent(this.selectedFile.blob_path)}/diff/${v1}/${v2}`);
            if (!response.ok) throw new Error('Failed to load diff');
            
            const diff = await response.json();
            diff.v1 = v1;
            diff.v2 = v2;
            this.currentDiff = diff;
            
            // Switch to diff view
            this.fileView.style.display = 'none';
            this.diffView.style.display = 'flex';
            
            // Update title
            this.diffTitle.textContent = `Comparing v${v1} → v${v2}`;
            
            // Render stats
            this.diffStats.innerHTML = `
                <span class="diff-stat added">+${diff.stats.lines_added} added</span>
                <span class="diff-stat removed">-${diff.stats.lines_removed} removed</span>
                <span class="diff-stat changed">${diff.stats.lines_changed} changed</span>
            `;
            
            this.renderDiff(diff);
        } catch (error) {
            console.error('Error loading diff:', error);
            this.diffContent.innerHTML = '<div class="loading">Error loading diff</div>';
        }
    }
    
    renderDiff(diff) {
        if (!diff.has_changes) {
            this.diffContent.innerHTML = '<div class="loading">No changes between these versions</div>';
            return;
        }
        
        if (this.diffMode === 'split') {
            this.renderSplitDiff(diff);
        } else {
            this.renderUnifiedDiff(diff);
        }
    }
    
    renderUnifiedDiff(diff) {
        const lines = diff.lines.map(line => {
            const oldNum = line.type === 'added' ? '' : (line.old_line_num || '');
            const newNum = line.type === 'removed' ? '' : (line.new_line_num || '');
            const sign = line.type === 'added' ? '+' : (line.type === 'removed' ? '-' : ' ');
            
            return `<div class="diff-line ${line.type}">
                <div class="diff-line-gutter">
                    <span class="diff-line-num ${line.type === 'removed' ? 'old' : ''}">${oldNum}</span>
                    <span class="diff-line-num ${line.type === 'added' ? 'new' : ''}">${newNum}</span>
                </div>
                <span class="diff-line-sign">${sign}</span>
                <span class="diff-line-content">${this.escapeHtml(line.content)}</span>
            </div>`;
        }).join('');
        
        this.diffContent.innerHTML = `<div class="diff-unified">${lines}</div>`;
    }
    
    renderSplitDiff(diff) {
        // Build parallel arrays for left (old) and right (new) sides
        const leftLines = [];
        const rightLines = [];
        
        let i = 0;
        while (i < diff.lines.length) {
            const line = diff.lines[i];
            
            if (line.type === 'context') {
                leftLines.push({ num: line.old_line_num, content: line.content, type: 'context' });
                rightLines.push({ num: line.new_line_num, content: line.content, type: 'context' });
                i++;
            } else if (line.type === 'removed') {
                // Check if next line is an addition (paired change)
                const nextLine = diff.lines[i + 1];
                if (nextLine && nextLine.type === 'added') {
                    leftLines.push({ num: line.old_line_num, content: line.content, type: 'removed' });
                    rightLines.push({ num: nextLine.new_line_num, content: nextLine.content, type: 'added' });
                    i += 2;
                } else {
                    leftLines.push({ num: line.old_line_num, content: line.content, type: 'removed' });
                    rightLines.push({ num: '', content: '', type: 'empty' });
                    i++;
                }
            } else if (line.type === 'added') {
                leftLines.push({ num: '', content: '', type: 'empty' });
                rightLines.push({ num: line.new_line_num, content: line.content, type: 'added' });
                i++;
            } else {
                i++;
            }
        }
        
        const renderPane = (lines, header, headerClass) => {
            const content = lines.map(line => `
                <div class="diff-split-line ${line.type}">
                    <span class="diff-split-line-num">${line.num}</span>
                    <span class="diff-split-line-content">${this.escapeHtml(line.content)}</span>
                </div>
            `).join('');
            
            return `
                <div class="diff-split-pane">
                    <div class="diff-split-header ${headerClass}">${header}</div>
                    <div class="diff-split-content">${content}</div>
                </div>
            `;
        };
        
        this.diffContent.innerHTML = `
            <div class="diff-split">
                ${renderPane(leftLines, `Version ${diff.v1} (old)`, 'old')}
                ${renderPane(rightLines, `Version ${diff.v2} (new)`, 'new')}
            </div>
        `;
    }
    
    closeDiff() {
        this.diffView.style.display = 'none';
        this.fileView.style.display = 'flex';
    }
    
    showRestoreModal(versionId) {
        const version = this.versions.find(v => v.id === versionId);
        if (!version) return;
        
        this.restoreMessage.textContent = `Are you sure you want to restore "${this.selectedFile.blob_path}" to version ${versionId}? This will overwrite the current file in blob storage.`;
        this.restoreModal.style.display = 'flex';
        
        // Set up confirm handler
        this.restoreConfirmBtn.onclick = () => this.restoreVersion(versionId);
    }
    
    closeRestoreModal() {
        this.restoreModal.style.display = 'none';
    }
    
    async restoreVersion(versionId) {
        try {
            const response = await fetch(
                `/api/files/${encodeURIComponent(this.selectedFile.blob_path)}/restore/${versionId}`,
                { method: 'POST' }
            );
            
            if (!response.ok) throw new Error('Failed to restore version');
            
            const result = await response.json();
            console.log('Restore result:', result);
            
            this.closeRestoreModal();
            
            // Refresh files after a short delay to allow syncer to pick up the change
            setTimeout(() => this.loadFiles(), 1000);
        } catch (error) {
            console.error('Error restoring version:', error);
            alert('Failed to restore version: ' + error.message);
        }
    }
    
    showFileView() {
        this.welcomeView.style.display = 'none';
        this.fileView.style.display = 'flex';
        this.diffView.style.display = 'none';
    }
    
    formatDate(dateString) {
        if (!dateString) return 'Unknown';
        
        const date = new Date(dateString);
        const now = new Date();
        const diffMs = now - date;
        const diffMins = Math.floor(diffMs / 60000);
        const diffHours = Math.floor(diffMs / 3600000);
        const diffDays = Math.floor(diffMs / 86400000);
        
        if (diffMins < 1) return 'Just now';
        if (diffMins < 60) return `${diffMins}m ago`;
        if (diffHours < 24) return `${diffHours}h ago`;
        if (diffDays < 7) return `${diffDays}d ago`;
        
        return date.toLocaleDateString() + ' ' + date.toLocaleTimeString();
    }
    
    escapeHtml(text) {
        if (!text) return '';
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    }
}

// Initialize app when DOM is ready
document.addEventListener('DOMContentLoaded', () => {
    window.app = new ToggleVault();
});
