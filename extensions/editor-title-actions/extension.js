const vscode = require('vscode');

function activate(context) {
  context.subscriptions.push(
    vscode.commands.registerCommand('editorTitleActions.togglePanel', () =>
      vscode.commands.executeCommand('workbench.action.togglePanel')
    )
  );
}

function deactivate() {}

module.exports = { activate, deactivate };