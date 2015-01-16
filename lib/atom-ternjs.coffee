TernServer = require './atom-ternjs-server'
TernClient = require './atom-ternjs-client'
DocumentationView = require './atom-ternjs-documentation-view'
AtomTernjsAutocomplete = require './atom-ternjs-autocomplete'
_ = require 'underscore-plus'
apd = require 'atom-package-dependencies'

class AtomTernInitializer

  disposables: []
  grammars: ['JavaScript', 'CoffeeScript']
  client: null
  documentationView: null
  currentProviderIdx: 0
  activeTextEditor: null

  # autocomplete
  autocompletePlus = null
  editorSubscription: null
  providers: []

  # config
  config:
    displayDocsIfAvailable:
      type: 'boolean'
      default: true

  activate: (state) ->
    @startServer()
    @registerEvents()
    @addComponents(state)

  serialize: ->
    atomTernjsViewState: @documentationView.serialize()

  activatePackage: ->
    atom.packages.activatePackage('autocomplete-plus')
      .then (pkg) =>
        @autocompletePlus = apd.require('autocomplete-plus')
        @registerEditors()

  deactivate: ->
    @stopServer()
    @unregisterEvents()
    # autocomplete
    @editorSubscription?.off()
    @editorSubscription = null
    @unregisterProviders()

  addComponents: (state) ->
    @documentationView = new DocumentationView(state.atomTernjsViewState)
    atom.views.getView(atom.workspace).appendChild(@documentationView.getElement())

  unregisterProviders: ->
    @providers.forEach (provider) =>
      @autocompletePlus.unregisterProvider provider
    @providers = []

  update: (editor) ->
    @client.update(editor.getURI(), editor.getText())

  findDefinition: ->
    cursor = @activeTextEditor.getLastCursor()
    position = cursor.getBufferPosition()
    @client.definition(@activeTextEditor.getURI(),
      line: position.row
      ch: position.column
    @activeTextEditor.getText()).then (data) =>
      if data?.start
        # check if definition is in current active TextEditor
        if @activeTextEditor.getPath().indexOf(data.file) > -1
          buffer = @activeTextEditor.getBuffer()
          cursor.setBufferPosition(buffer.positionForCharacterIndex(data.start))
          return
        # else open the file and set cursor position to definition
        atom.workspace.open(data.file).then (textEditor) ->
          buffer = textEditor.getBuffer()
          cursor = textEditor.getLastCursor()
          cursor.setBufferPosition(buffer.positionForCharacterIndex(data.start))
          return
    , (err) ->
      console.error 'error', err

  registerEvents: ->
    @disposables.push atom.workspace.onDidOpen (e) =>
      return unless e.item and @isValidEditor(e.item)
      @startServer()
    @disposables.push atom.workspace.onDidChangeActivePaneItem =>
      @setCurrentProvider()

  isValidEditor: (editor) ->
    return false if editor.mini
    return false if !editor.getGrammar
    return false if editor.getGrammar().name not in @grammars
    return true

  setCurrentProvider: ->
    @activeTextEditor = atom.workspace.getActiveTextEditor()
    return unless @activeTextEditor
    for provider, idx in @providers
      provider.isActive = false
      if provider.editor.id is @activeTextEditor.id
        @currentProviderIdx = idx
        provider.isActive = true
        break

  registerEditors: ->
    @editorSubscription = atom.workspace.observeTextEditors (editor) =>
      return unless @isValidEditor(editor)
      @registerEditor(editor)
      @setCurrentProvider()

  registerEditor: (editor) ->
    _buffer = editor.getBuffer()
    _editor = editor
    index = @providers.push new AtomTernjsAutocomplete(_editor, _buffer, @client, @autocompletePlus, @documentationView)
    @disposables.push _buffer.onDidStopChanging =>
      _.throttle @update(editor), 2000
    @disposables.push _buffer.onDidStopChanging =>
      _.throttle @providers[@currentProviderIdx].callPreBuildSuggestions(), 500
    @autocompletePlus.registerProviderForEditor @providers[index - 1], _editor
    @providers[index - 1].init()

  unregisterEvents: ->
    for disposable in @disposables
      disposable.dispose()
    @disposables = []

  startServer: ->
    return unless !@server?.process and atom.project.getDirectories()[0]
    @server = new TernServer()
    @server.start (port) =>
      if !@client
        @client = new TernClient()
      @client.port = port
      if !@autocompletePlus
        @activatePackage()
        @registerCommands()

  registerCommands: ->
    atom.commands.add 'atom-text-editor', 'tern:definition': (event) =>
        @findDefinition()
    atom.commands.add 'atom-text-editor', 'tern:startCompletion': (event) =>
      @providers[@currentProviderIdx].callPreBuildSuggestions(true)
    atom.commands.add 'atom-text-editor', 'tern:stop': (event) =>
      @stopServer()
    atom.commands.add 'atom-text-editor', 'tern:start': (event) =>
      @startServer()
    atom.commands.add 'atom-text-editor', 'tern:cancel': (event) =>
      for provider in @providers
        provider.cancelAutocompletion()

  stopServer: ->
    return unless @server?.process
    @server.stop()

#expose init class
module.exports = new AtomTernInitializer()
