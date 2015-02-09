util = require("util")
serialport = require("serialport")
buffertools = require("buffertools")
Q = require("q")
EventEmitter = require("events").EventEmitter

instances = {}

class Modem
  constructor: (device, options={}) ->
    options.lineEnd = "\r\n"  unless options.lineEnd
    options.baudrate = 115200  unless options.baudrate

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
        .catch (error) ->
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

  execute: (command, timeout=false, response, pdu=false, callback) ->  # command, timeout, response, pdu, callback
    return  unless command

    args = [].slice.apply arguments
    callback = if args.length > 1 and typeof args[-1..][0] is 'function' then args.pop() else null
    pdu = if args.length > 1 and typeof args[-1..][0] is 'boolean' then args.pop() else null
    response = if args.length > 1 and typeof args[-1..][0] is 'string' then args.pop() else null
    timeout = if args.length > 1 and typeof args[-1..][0] is 'number' then args.pop() else 5000

    defer = Q.defer()
    defer.execution =
      exec: command
      response: response
      callback: callback
      pdu: pdu
      timeout: timeout

    fetchExecution.call this  if @executions.push(defer) is 1
    defer.promise

  fetchExecution = ->
    defer = @executions[0]
    return  unless defer
    execution = defer.execution
    @write "#{execution.exec}\r"
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
    return  if line.substr(0, 2) is "AT"
    return  if processUnboundLine.call(this, line)
    
    # special handling for ring
    if @isRinging and line is "NO CARRIER"
      @isRinging = false
      @emit "end ring"
      return
    @lines.push line
    processLines.call this
    return

  isResultCode = (line) ->
    /(^OK|ERROR|BUSY|DATA|NO CARRIER|COMMAND NOT SUPPORT|\+CME|> $)|(^CONNECT( .+)*$)/i.test line

  isErrorCode = (line) ->
    /^(\+CME\s)?ERROR(\:.*)?|NO CARRIER|COMMAND NOT SUPPORT$/i.test line

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
    cmd = execution.exec.split("\r", 1).shift()

    if responseCode is "> "
      if execution and execution.pdu
        pduSize = execution.pdu.length
        b = new Buffer(pduSize + 1)
        b.write execution.pdu
        b.writeUInt8 26, pduSize
        @write b
        execution.pdu = null
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
        execution.callback?(new Error("Responsed Error: '#{responseCode}'"), null)
        defer.reject response
        return
      
      if typeof response['success'] isnt 'undefined' and not response['success']
        execution.callback?(new Error("Missed the awaited response. Response was: #{responseCode}"), null)
        defer.reject response
        return

      execution.callback?(null, response)
      defer.resolve response

    fetchExecution.call this  if @executions.length
    return

  unboundExprs = [
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
      expr: /^\+CMTI:(.+)$/i
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
      expr: /^\+CUSD:(.+)$/i
      func: (m) ->
        @emit "ussd", m[1]
        return
    }
  ]
  


init = (device, options) ->
  device = device or "/dev/ttyAMA0"
  instances[device] = new Modem(device, options)  unless instances[device]
  instances[device]

module.exports = init