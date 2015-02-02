util = require("util")
serialport = require("serialport")
buffertools = require("buffertools")
Q = require("q")
EventEmitter = require("events").EventEmitter

instances = {}

class Modem
  constructor: (device, options) ->
    options = options or {}
    options.lineEnd = "\r\n"  unless options.lineEnd
    options.baudrate = 115200  unless options.baudrate
    @options = options
    @opened = false
    @device = device
    @port = null
    @buffer = new Buffer(0)
    @lines = []
    @executions = []
    buffertools.extend @buffer
    return
  
  util.inherits Modem, EventEmitter

  open: (timeout) ->
    self = this
    if self.opened
      self.emit "open"
      return
    timeout = timeout or 5000

    @port = new serialport.SerialPort(@device,
      baudrate: @options.baudrate
      parser: serialport.parsers.raw
    )
    
    @port.on "open", ->
      @on "data", (data) ->
        self.buffer = Buffer.concat([
          self.buffer
          data
        ])

        readBuffer.call self
        return

      self.execute(command: "AT", timeout: timeout)
        .then ->
          self.emit "open"
          return
        .catch (error) ->
          self.emit "error", error
          return
        .done()
      return

    @port.on "close", ->
      self.opened = false
      self.emit "close"
      return

    @port.on "error", (err) ->
      self.emit "error", err
      return

    @opened = true
    return

  close: ->
    @port.close()
    @port = null
    instances[@device] = null
    return

  write: (data, callback) ->
    @port.write data, callback
    return

  writeAndWait: (data, callback) ->
    self = this
    @write data, ->
      self.port.drain callback
      return
    return

  execute: (command) ->
    command = command: String(command)  unless typeof command is "object"
    return  unless command.command
    defer = Q.defer()
    defer.execution =
      exec: command.command
      pdu: command.pdu or null
      timeout: command.timeout or false

    fetchExecution.call this  if @executions.push(defer) is 1
    defer.promise

  #
  #    Modem.prototype.execute = function(command) {
  #      var p = null;
  #      var timeout;
  #
  #      if (typeof command == 'object') {
  #
  #        if (command.timeout) {
  #          timeout = Number(timeout);
  #        }
  #
  #        if (command.defers) {
  #          defer_times = command.defers || 1;
  #        }
  #
  #        p = command.pdu;
  #        command = command.command;
  #
  #      }
  #      //
  #      var defer = Q.defer();
  #
  #      defer.command = command.split("\r", 1).shift();
  #      defer.pdu = p;
  #      this.defers.push(defer);
  #      this.write(command + "\r");
  #
  #      if (timeout) {
  #        setTimeout(function() {
  #          defer.reject(new Error('timed out'));
  #        }, timeout);
  #      }
  #
  #      return defer.promise;
  #    }
  #
  fetchExecution = ->
    defer = @executions[0]
    return  unless defer
    execution = defer.execution
    @write "#{execution.exec}\r"
    if execution.timeout
      defer.timer = setTimeout ->
        defer.reject new Error("timed out")
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
    if @ringing and line is "NO CARRIER"
      @ringing = false
      @emit "end ring"
      return
    @lines.push line
    processLines.call this
    return

  isResultCode = (line) ->
    /(^OK|ERROR|BUSY|DATA|NO CARRIER|COMMAND NOT SUPPORT|> $)|(^CONNECT( .+)*$)/i.test line

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
      cmd = execution.exec.split("\r", 1).shift()
      @executions.shift()
      if defer.timer
        clearTimeout defer.timer
        defer.timer = null
      if responseCode in ["ERROR", "COMMAND NOT SUPPORT"]
        defer.reject
          code: responseCode
          command: cmd

        return
      defer.resolve
        code: responseCode
        command: cmd
        lines: @lines

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
        @ringing = true
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