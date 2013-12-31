system = require('system')
fs = require('fs')
page = require("webpage").create()


if system.args.length < 5
  console.error "This program takes 4 or 5 arguments:"
  console.error ""
  console.error "1. The absolute path to this directory" # (I know, it's annoying but I need it to load the jquery, mathjax, and the like)
  console.error "2. Input CSS/LESS file (ie '/path/to/style.css')"
  console.error "3. Absolute path to Input html file (ie '/path/to/file.xhtml)"
  console.error "4. Output (X)HTML file"
  console.error "5. Output CSS file (optional)"
  console.error ""
  console.error "If the output CSS file is not specified then the styles will be 'baked' into the HTML in style tags."
  console.error "This option is useful for performing a diff on the HTML and CSS to see what changed."
  phantom.exit 1

programDir = system.args[1]

cssFile = system.args[2]
address = system.args[3]

# Verify address is an absolute path
# TODO: convert relative paths to absolute ones
if address[0] != '/'
  console.error "Path to HTML file does not seem to be an absolute path. For now it needs to start with a '/'"
  phantom.exit 1
address = "file://#{address}"

OUTPUT_XHTML_PATH = system.args[4]
OUTPUT_CSS_PATH = system.args[5]

SPECIAL_CSS_FILE_NAME = '__AUTOGENERATED_CSS_FILE'

config =
  bakeInAllStyles: not OUTPUT_CSS_PATH


page.onConsoleMessage = (msg) ->
  console.log("LOG:#{msg}")


OPEN_FILES = {}

page.onAlert = (msg) ->
  try
    msg = JSON.parse(msg)
  catch err
    console.log "Could not parse: #{msg}"
    return

  switch msg.type
    when 'PHANTOM_END'
      phantom.exit(0)
    when 'FILE_START'
      # TODO: uncomment for large files: console.log("Start Writing #{msg.path}")
      filePath = null
      switch msg.path
        when '__PhantomJS_MAIN_XHTML_FILE' then filePath = OUTPUT_XHTML_PATH
        when SPECIAL_CSS_FILE_NAME then filePath = OUTPUT_CSS_PATH
        else
          filePath = msg.path

      OPEN_FILES[msg.path] = {
        lines: 0
        file: fs.open(filePath, 'w')
      }
    when 'FILE_END'
      # TODO: uncomment for large files: console.log("End Writing #{msg.path}")
      OPEN_FILES[msg.path].file.close()
      delete OPEN_FILES[msg.path]

    else
      info = OPEN_FILES[msg.path]
      # TODO: uncomment for large files:
      # info.lines += 1
      # if info.lines % 10000 == 1
      #   console.log("Writing #{msg.path}")
      info.file.write(msg.msg)


LOCK_STATE = {}

# Confirm changes the name of the file
page.onConfirm = (fileName) ->
  # Using indexOf because apparently we can't compare 2 strings in JS if they came from different sources...
  if fileName.indexOf('__PhantomJS_MUTEX') >= 0
    lockName = fileName.split('_')[4]
    if fileName.indexOf('_UNLOCK') >= 0
      delete LOCK_STATE[lockName]
      locks = (key for key of LOCK_STATE)
      if locks.length != 0
        console.log "UNLOCKED '#{lockName}' but still locked on the following: #{ locks }"
      else
        console.log "UNLOCKED '#{lockName}' and Exiting!"
        phantom.exit()
      return true
    else
      console.log "LOCKED '#{lockName}'"
      LOCK_STATE[lockName] = true
    return true
  else if fileName.indexOf('__PhantomJS?') >= 0
    return true
  lines = 0
  true

console.log "Reading CSS file at: #{cssFile}"
lessFile = fs.read(cssFile, 'utf-8')
lessFilename = "file://#{cssFile}"

console.log "Opening page at: #{address}"
startTime = new Date().getTime()




page.open encodeURI(address), (status) ->
  if status != 'success'
    console.error "File not FOUND!!"
    phantom.exit(1)

  console.log "Loaded? #{status}. Took #{((new Date().getTime()) - startTime) / 1000}s"

  loadScript = (path) ->
    if page.injectJs(path)
    else
      console.error "Could not find #{path}"
      phantom.exit(1)

  loadScript(programDir + '/lib/phantomjs-hacks.js')
  loadScript(programDir + '/lib/dom-to-xhtml.js')
  loadScript(programDir + '/node_modules/css-polyfills/dist.js')
  # loadScript(programDir + '/rasterize.js')

  needToKeepWaiting = page.evaluate((lessFile, lessFilename, config, SPECIAL_CSS_FILE_NAME) ->


    # File serialization is sent to console.log()
    outputter = (path, msg, type='BYTES') ->
      alert(JSON.stringify({path:path, msg:msg, type:type}))

    window.require ['jquery', 'cs!polyfill-path/index'], ($, CSSPolyfills) ->
      $root = $('html')

      matchingRules = {}
      for plugin in CSSPolyfills.DEFAULT_PLUGINS
        _.extend(matchingRules, plugin.rules)

      class StyleBaker
        rules:
          # The magic `*` rule has an additional argument, the name of the rule
          '*': (env, name) ->
            # Note: ellipses are not valid in here because of how phantomjs works.
            # CoffeeScript adds a helper function called `__slice`.
            if not (name of matchingRules)
              $context = env.helpers.$context
              $context.addClass('js-polyfill-styles')
              styles = $context.data('js-polyfill-styles') or {}
              value = ''
              for arg, i in arguments
                continue if i < 2
                value += arg.eval(env).toCSS(env)

              # only put it in the 1st time since rules are matched in reverse order.
              #
              # For example, the following rules:
              #
              #     color: blue;
              #     color: red;
              #
              # This ensures the style used is `red` since the FixedPointRunner moves up until a rule is "understood"
              styles[name] ?= []
              if styles[name].indexOf(value) < 0 # Cannot use `x not in y because of phantomjs`
                styles[name].push(value)

              $context.data('js-polyfill-styles', styles)

            # Deliberately do not "understand" so this function keeps walking up
            return false


      plugins = null
      plugins = [new StyleBaker()] if config.bakeInAllStyles
      poly = new CSSPolyfills {plugins: plugins}

      # For large files output the selector matches and ticks (to see progress)
      poly.on 'selector.end', (selector, matches) ->
        if 0 == matches
          console.log("Uncovered: #{selector}")
        else
          console.log("Covered: #{matches}: #{selector}")

      poly.on 'tick.start', (count) -> console.log "DEBUG: Starting TICK #{count}"

      poly.run $root, lessFile, lessFilename, (err, newCSS) ->
        throw new Error(err) if err

        if config.bakeInAllStyles
          # Bake in the styles.
          console.log('Baking styles...')
          $root.find('.js-polyfill-styles').each (i, el) ->
            $el = $(el)
            style = []
            rules = $el.data('js-polyfill-styles')

            # Sort the rule names alphabetically so they are canonicalized (for diffing)
            ruleNames = (key for key of rules)
            ruleNames.sort()

            # Use the sorted list of rule names for canonicalizing
            for ruleName in ruleNames
              ruleValues = rules[ruleName]
              for ruleStr in ruleValues
                style.push("#{ruleName}:#{ruleStr}; ")
                # The FixedPointRunner adds `data-` attributes for each rule that is matched.
                # Remove it from the HTML
              $el.removeAttr("data-js-polyfill-rule-#{ruleName}")

            $el.attr('style', style.join('').trim())
            $el.removeClass('js-polyfill-styles')


          # Remove autogenerated classes
          $root.find('.js-polyfill-autoclass').each (i, el) ->
            $el = $(el)

            # remove everything after `js-polyfill-autoclass (this includes all autogenerated classes)
            cls = $el.attr('class') or ''
            if cls.indexOf('js-polyfill-autoclass') >= 0
              cls = cls.substring(0, cls.indexOf('js-polyfill-autoclass'))

            cls = cls.trim()

            $el.attr('class', cls)


        # Hack to serialize out the HTML (sent to the console)
        console.log 'Serializing (X)HTML back out from WebKit...'
        MAIN_XHTML = '__PhantomJS_MAIN_XHTML_FILE'
        aryHack =
          push: (str) -> outputter(MAIN_XHTML, str)

        outputter(MAIN_XHTML, null, 'FILE_START')
        outputter(MAIN_XHTML, '<html xmlns="http://www.w3.org/1999/xhtml">')
        window.dom2xhtml.serialize($('body')[0], aryHack)
        outputter(MAIN_XHTML, '</html>')
        outputter(MAIN_XHTML, null, 'FILE_END')

        if not config.bakeInAllStyles
          outputter(SPECIAL_CSS_FILE_NAME, null, 'FILE_START')
          outputter(SPECIAL_CSS_FILE_NAME, newCSS)
          outputter(SPECIAL_CSS_FILE_NAME, null, 'FILE_END')

        outputter('', null, 'PHANTOM_END')

  , lessFile, lessFilename, config, SPECIAL_CSS_FILE_NAME)

  if not needToKeepWaiting
    phantom.exit()
