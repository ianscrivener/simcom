fs = require 'fs'
util = require 'util'
serialport = require 'serialport'
buffertools = require 'buffertools'
Q = require 'q'
EventEmitter = require('events').EventEmitter

log = null

instances = {}

errorCodes =
  '0': "phone failure"
  '1': "no connection to phone"
  '2': "phone-adaptor link reserved"
  '3': "operation not allowed"
  '4': "operation not supported"
  '5': "PH-SIM PIN required"
  '6': "PH-FSIM PIN required"
  '7': "PH-FSIM PUK required"
  '10': "SIM not inserted"
  '11': "SIM PIN required"
  '12': "SIM PUK required"
  '13': "SIM failure"
  '14': "SIM busy"
  '15': "SIM wrong"
  '16': "incorrect password"
  '17': "SIM PIN2 required"
  '18': "SIM PUK2 required"
  '20': "memory full"
  '21': "invalid index"
  '22': "not found"
  '23': "memory failure"
  '24': "text string too long"
  '25': "invalid characters in text string"
  '26': "dial string too long"
  '27': "invalid characters in dial string"
  '30': "no network service"
  '31': "network timeout"
  '32': "network not allowed - emergency calls only"
  '40': "network personalization PIN required"
  '41': "network personalization PUK required"
  '42': "network subset personalization PIN required"
  '43': "network subset personalization PUK required"
  '44': "service provider personalization PIN required"
  '45': "service provider personalization PUK required"
  '46': "corporate personalization PIN required"
  '47': "corporate personalization PUK required"
  '100': "Unknown"
  '103': "illegal MS"
  '106': "illegal ME"
  '107': "GPRS services not allowed"
  '111': "PLMN not allowed"
  '112': "location area not allowed"
  '113': "roaming not allowed in this location area"
  '132': "service option not supported"
  '133': "requested service option not subscribed"
  '134': "service option temporarily out of order"
  '148': "unspecified GPRS error"
  '149': "PDP authentication failure"
  '150': "invalid mobile class"
  '300': "ME failure"
  '301': "SMS ME reserved"
  '302': "Operation not allowed"
  '303': "Operation not supported"
  '304': "Invalid PDU mode"
  '305': "Invalid text mode"
  '310': "SIM not inserted"
  '311': "SIM pin necessary"
  '312': "PH SIM pin necessary"
  '313': "SIM failure"
  '314': "SIM busy"
  '315': "SIM wrong"
  '316': "SIM PUK required"
  '317': "SIM PIN2 required"
  '318': "SIM PUK2 required"
  '320': "Memory failure"
  '321': "Invalid memory index"
  '322': "Memory full"
  '330': "SMSC address unknown"
  '331': "No network"
  '332': "Network timeout"
  '500': "Unknown"
  '512': "SIM not ready"
  '513': "Unread records on SIM"
  '514': "CB error unknown"
  '515': "PS busy"
  '528': "Invalid (non-hex) chars inPDU"
  '529': "Incorrect PDU length"
  '530': "Invalid MTI"
  '531': "Invalid (non-hex) chars in address"
  '532': "Invalid address (no digits read)"
  '533': "Incorrect PDU length (UDL)"
  '534': "Incorrect SCA length"
  '536': "Invalid First Octet (should be 2 ore 34)"
  '537': "Invalid Command type"
  '538': "SRR bit not set"
  '539': "SRR bit set"
  '540': "Invalid User Data Header IE"


class Modem

  constructor: (device, options={}) ->
    options.lineEnd = "\r\n"  unless options.lineEnd
    options.baudrate = 115200  unless options.baudrate

    log = fs.createWriteStream options.log  if options.log?

    @options = options
    @device = device

    @tty = null
    @opened = false
    @lines = []
    @executions = []

    @isCalling = false
    @isRinging = false
    @isBusy = false

    @buffer = new Buffer(0)
    buffertools.extend @buffer
    return

  util.inherits Modem, EventEmitter

  open: (timeout) ->
    self = this
    if self.opened
      self.emit "open"
      return

    timeout = timeout or 5000

    @tty = new serialport.SerialPort(@device,
      baudrate: @options.baudrate
      parser: serialport.parsers.raw
      # parser: serialport.parsers.readline(@options.lineEnd)
    )

    @tty.on "open", ->
      @on "data", (data) ->
        self.buffer = Buffer.concat([
          self.buffer
          data
        ])

        readBuffer.call self
        return

      self
        .execute "AT", timeout
        .then ->
          self.emit "open"
          return
        .fail (error) ->
          self.emit "error", error
          return
        .done()

      return

    @tty.on "close", ->
      self.opened = false
      self.emit "close"
      return

    @tty.on "error", (err) ->
      self.emit "error", err
      return

    @opened = true
    return

  close: ->
    @tty.close()
    @tty = null
    instances[@device] = null
    delete instances[@device]
    return

  write: (data, callback) ->
    @tty.write data, callback
    return

  writeAndWait: (data, callback) ->
    self = this
    @write data, ->
      self.tty.drain callback
      return
    return

  execute: (command, args...) ->
    return  unless command?

    callback = if typeof args[-1..][0] is 'function' then args.pop() else null
    pdu = if typeof args[-1..][0] in ['boolean','object'] then args.pop() else false
    response = if typeof args[-1..][0] is 'string' then args.pop() else null
    timeout = if typeof args[-1..][0] is 'number' then args.pop() else false

    defer = Q.defer()
    defer.execution =
      exec: command
      response: response
      callback: callback
      pdu: pdu
      timeout: timeout

    log and log.write JSON.stringify(defer.execution) + "\n"

    fetchExecution.call this  if @executions.push(defer) is 1
    defer.promise

  fetchExecution = ->
    defer = @executions[0]
    return  unless defer
    execution = defer.execution
    cmd = execution.exec?.split("\r", 1).shift()
    @write "#{cmd}\r"
    if execution.timeout
      defer.timer = setTimeout ->
        defer.reject new Error("Command '#{execution.exec}' failed by timed out")
        return
      , execution.timeout
    return

  readBuffer = ->
    self = this
    lineEndLength = self.options.lineEnd.length
    lineEndPosition = buffertools.indexOf(self.buffer, self.options.lineEnd)
    if lineEndPosition is -1
      processLine.call this, @buffer.toString()  if @buffer.length is 2 and @buffer.toString() is "> "
      return
    line = @buffer.slice(0, lineEndPosition)
    newBuffer = new Buffer(@buffer.length - lineEndPosition - lineEndLength)
    @buffer.copy newBuffer, 0, lineEndPosition + lineEndLength
    @buffer = newBuffer

    processLine.call this, line.toString("ascii")
    process.nextTick readBuffer.bind(this)
    return

  processUnboundLine = (line) ->
    i = 0

    while i < unboundExprs.length
      u = unboundExprs[i]
      m = line.match(u.expr)
      if m
        u.func and u.func.call(this, m)
        unless u.unhandle
          @emit "urc", m, u.expr
          return true
      i++
    false

  processLine = (line) ->
    # echo'd line
    # console.log "#", line
    log and log.write "#{line}\n"

    return  if line.substr(0, 2) is "AT"
    return  if processUnboundLine.call(this, line)

    @lines.push line
    processLines.call this
    return

  isResultCode = (line) ->
    /(^OK|ERROR|BUSY|DATA|NO ANSWER|NO CARRIER|NO DIALTONE|OPERATION NOT ALLOWED|COMMAND NOT SUPPORT|\+CM[EPS]*|> $)|(^CONNECT( .+)*$)/i.test line

  isErrorCode = (line) ->
    /^(\+CM[EPS]\s)?ERROR(\:.*)?|BUSY|NO ANSWER|NO CARRIER|NO DIALTONE|OPERATION NOT ALLOWED|COMMAND NOT SUPPORT$/i.test line

  processLines = ->
    return  unless @lines.length
    return  unless isResultCode(@lines[@lines.length - 1])
    @lines.shift()  if @lines[0].trim() is ""
    processResponse.call this
    @lines = []
    return

  processResponse = ->
    responseCode = @lines.pop()
    defer = @executions[0]
    execution = defer and defer.execution

    exec = execution?.exec?.split("\r") or ""
    cmd = exec.shift()

    if responseCode is "> "
      if execution and exec.length
        @write "#{exec.shift()}\r\x1A"
      return

    if responseCode.match(/^CONNECT( .+)*$/i)
      if execution and execution.pdu
        @write execution.pdu
        execution.pdu = null
      return

    if defer
      @executions.shift()

      response =
        code: responseCode
        command: cmd
        lines: @lines

      response.success = responseCode.match(new RegExp("^#{execution.response}$", 'i'))?  if execution.response

      if defer.timer
        clearTimeout defer.timer
        defer.timer = null

      if isErrorCode responseCode
        error = new Error("#{cmd} responsed error: '#{responseCode}'")

        if m = responseCode.match /^\+CM[ES] ERROR\: (\d+)/
          error = errorCodes[m[1]]  if errorCodes[m[1]]?

        error.code = responseCode

        execution.callback?(error, null)
        defer.reject error
        return

      if typeof response['success'] isnt 'undefined' and not response['success']
        error = new Error("#{cmd} missed the awaited response. Response was: #{responseCode}")
        error.code = responseCode

        execution.callback?(error, null)
        defer.reject error
        return

      execution.callback?(null, response)
      defer.resolve response

    fetchExecution.call this  if @executions.length
    return

  unboundExprs = [
    {
      expr: /^NO CARRIER$/i
      func: (m) ->
        if @isRinging
          @isRinging = false
          @emit "end ring"

        if @isCalling
          @isCalling = false
          @emit "end call"
        return
    }
    {
      expr: /^OVER-VOLTAGE WARNNING$/i
      func: (m) ->
        @emit "over-voltage warnning"
        return
    }
    {
      expr: /^RING$/i
      func: (m) ->
        @isRinging = true
        @emit "ring"
        return
    }
    {
      expr: /^\+CMTI: (.+)$/i
      func: (m) ->
        @emit "new message", m[1]
        return
    }
    {
      expr: /^\+CPIN: (NOT .+)/i
      unhandled: true
      func: (m) ->
        @emit "sim error", m[1]
        return
    }
    {
      expr: /^\+CUSD: (.+)$/i
      func: (m) ->
        @emit "ussd", m[1]
        return
    }
    {
      expr: /^\+CMGS: (.+)$/i
      func: (m) ->
        return
    }
    {
      unhandled: true
      expr: /^\+CREG: (\d)$/i
      func: (m) ->
        @isBusy = false
        return
    }
  ]



init = (device, options) ->
  device = device or "/dev/ttyAMA0"
  instances[device] = new Modem(device, options)  unless instances[device]
  instances[device]

module.exports = init

process.on 'exit', (code) ->
  log and log.end()
  return
