util = require("util")
Q = require("q")
pdu = require("pdu")
EventEmitter = require("events").EventEmitter

simple_methods =
  productID      : "ATI"
  manufacturerID : "AT+GMI"
  modelID        : "AT+GMM"
  globalID       : "AT+GOI"
  IMEI           : "AT+GSN"
  subscriberID   : "AT+CIMI"



class SimCom
  constructor: (device, options) ->
    @modem = require("./modem")(device, options)
    self = this
    
    # delegates modem events
    [
      "open"
      "close"
      "error"
      "ring"
      "end ring"
      "over-voltage warnning"
    ].forEach (e) ->
      self.modem.on e, ->
        args = Array::slice.call(arguments)
        args.unshift e
        self.emit.apply self, args
        return

      return

    @modem.on "new message", handleNewMessage.bind(this)
    @modem.on "ussd", handleUSSD.bind(this)
    @modem.open()
    return


  util.inherits SimCom, EventEmitter

  close: ->
    @modem.close()
    return

  ###*
  Execute a Raw AT Command
  @param command Raw AT Command
  @returns Promise
  ###
  execute: (command) ->
    @modem.execute command

  parse = (s) ->
    quoted = false
    item = ""
    items = []
    i = 0

    while i < s.length
      valid = false
      switch s[i]
        when "\""
          quoted = not quoted
        when ","
          valid = quoted
          unless quoted
            items.push item
            item = ""
        else
          valid = true
      item += s[i]  if valid
      i++
    items.push item  if item
    items

  handleNewMessage = (m) ->
    m = parse(m)
    m =
      storage: m[0]
      index: Number(m[1])
      type: (if m.length > 2 then m[2] else "SMS")

    @emit "new message", m
    return

  handleUSSD = (m) ->
    m = parse(m).map (e) -> e.trim()
    m =
      type: Number(m[0])
      str: m[1]
      dcs: Number(m[2])

    m.str = (if m.dcs is 72 then pdu.decode16Bit(m.str) else pdu.decode7Bit(m.str))
    @emit "ussd", m
    return

  downloadMMS = (type, data, name) ->
    throw new Error("Invalid MMS Download Type")  unless /^(PIC|TEXT|TITLE)$/i.test(type)
    if data and data.length
      type = type.toUpperCase()
      timeout = Math.max(200000, Math.ceil(data.length / @modem.options.baudrate * 1000 * 8))
      param = "\"" + type + "\"," + data.length + "," + timeout
      param += ",\"" + name + "\""  if name
      self = this
      self.invoke("ATE1").then ->
        self.invoke
          command: "AT+CMMSDOWN=#{param}"
          pdu: data
          timeout: timeout

  Object.keys(simple_methods).forEach (name) ->
    SimCom::[name] = ->
      defer = Q.defer()
      @execute(simple_methods[name]).then((res) ->
        res.lines = res.lines.filter (val) -> val?
        defer.resolve (if res.lines.length > 1 then res.lines else res.lines.shift())
        return
      ).catch (res) ->
        defer.reject res
        return

      defer.promise

    return

  @extractResponse = @::extractResponse = (resp, readPDU) ->
    return  if not resp or not resp.command or not resp.lines or not resp.lines.length
    cmd = resp.command.match(/^AT([^\=\?]*)/)
    return  if not cmd or cmd.length < 2
    cmd = cmd[1]
    result = []
    needPDU = false
    pduResponse = null
    cmdMatched = false
    i = 0

    while i < resp.lines.length
      line = resp.lines[i]
      if line is ""
        cmdMatched = false
        continue
      unless needPDU
        unless cmdMatched
          if line.substr(0, cmd.length) is cmd
            tokens = line.substr(cmd.length).match(/(\:\s*)*(.+)*/)
            if tokens and tokens.length > 2
              line = tokens[2]
              cmdMatched = true
        if cmdMatched
          if line
            unless readPDU
              result.push line
            else
              pduResponse =
                response: line
                pdu: null
          needPDU = readPDU
      else
        pduResponse.pdu = line
        result.push pduResponse
        needPDU = false
      i++
    result

  ###*
  Invoke a RAW AT Command, Catch and process the responses.
  @param command RAW AT Command
  @param resultReader Callback for processing the responses
  @param readPDU Try to read PDU from responses
  @returns Promise
  ###
  invoke: (command, resultReader, readPDU) ->
    defer = Q.defer()
    self = this
    @execute(command)
      .then (res) ->
        result = SimCom.extractResponse(res, readPDU) or null
        result = resultReader.call(self, result)  if resultReader
        defer.resolve result
        return
      .catch (error) ->
        defer.reject error
        return
    defer.promise

  serviceProvider: ->
    @invoke "AT+CSPN?", (lines=[]) ->
      lines.shift().match(/"([^"]*)"/).pop()

  # TODO:
  answerCall: (callback) ->
    @invoke "ATA", (res) ->
      console.log res
    , true

  # TODO:
  dial: (number, callback) ->
    if @inACall
      callback new Error("Currently in a call"), []
    else if not number or not String(number).length
      callback new Error("Did not specify a phone number"), []
    else
      @inACall = true
      @invoke "ATD#{number};", (res) ->
        console.log res

  # TODO:
  hangUp: (callback) ->
    @invoke "ATH", (res) ->
      console.log res

  listSMS: (stat) ->
    @invoke "AT+CMGL=#{stat}", (res) ->
      res.map (m) ->
        infos = parse(m.response)
        index: Number(infos[0])
        stat: infos[1]
        message: pdu.parse(m.pdu)
    , true

  readSMS: (index, peek) ->
    @invoke "AT+CMGR=#{index}" + (if peek then 0 else 1), (res) ->
      pdu.parse res.shift().pdu
    , true

  sendSMS: (receiver, text) ->
    p = pdu.generate(encoding: "16bit", receiver: receiver, text: text).shift()
    pduLength = (p.length / 2) - 1
    @invoke
      command: "AT+CMGS=#{pduLength}"
      pdu: p
    , (res) ->
      res.shift()

  setBearerParam: (id, tag, value) ->
    @invoke "AT+SAPBR=3,#{id},\"#{tag}\",\"#{value}\""

  setBearerParams: (id, params) ->
    self = this
    Object.keys(params).reduce (d, k) ->
      d.then ->
        self.setBearerParam id, k, params[k]
        return
    , Q(0)

  getBearerParams: (id) ->
    @invoke "AT+SAPBR=4,#{id}", (lines) ->
      lines.reduce (m, v) ->
        v = v.split(":", 2)
        m[v[0].trim()] = v[1].trim()
        m
      , {}

  activateBearer: (id) ->
    @invoke "AT+SAPBR=1,#{id}"

  deactivateBearer: (id) ->
    @invoke "AT+SAPBR=0,#{id}"

  queryBearer: (id) ->
    @invoke "AT+SAPBR=2,#{id}", (lines) ->
      line = lines.shift() or ""
      m = line.match(/(.+),(.+),\"([^"]*)/)
      cid = Number(m[1])
      status_code = Number(m[2])
      status = status_code
      ip = m[3]
      status = switch status_code
        when 1 then "connected"
        when 2 then "closing"
        when 3 then "closed"
        else "unknown"
      id: cid
      status_code: status_code
      status: status
      ip: ip


  startBearer: (id) ->
    self = this
    self.queryBearer(id).then (res) ->
      self.activateBearer id  if not res or res.status_code isnt 1

  initMMS: ->
    @invoke "AT+CMMSINIT"

  terminateMMS: ->
    @invoke "AT+CMMSTERM"

  startMMS: ->
    self = this
    self.initMMS().then null, error = ->
      self.terminateMMS().then ->
        self.initMMS()

  editMMS: (edit) ->
    @invoke "AT+CMMSEDIT=" + Number(edit or false)

  downloadMMSText: (text, name) ->
    downloadMMS.call this, "TEXT", text, name

  downloadMMSTitle: (title) ->
    downloadMMS.call this, "TITLE", title

  downloadMMSPicture: (data, name) ->
    downloadMMS.call this, "PIC", data, name

  setMMSRecipient: (address) ->
    if Array.isArray(address)
      self = this
      return Q.all(address.map((addr) ->
        self.setMMSRecipient addr
      ))
    @invoke "AT+CMMSRECP=\"#{address}\""

  viewMMS: ->
    @invoke "AT+CMMSVIEW", (lines) ->
      tokens = parse lines.shift()
      files = lines.map (line) ->
        t = parse line
        index : Number(t[0])
        name  : t[1]
        type: switch Number(t[2])
          when 2 then "text"
          when 3 then "text/html"
          when 4 then "text/plain"
          when 5 then "image"
          when 6 then "image/gif"
          when 7 then "image/jpg"
          when 8 then "image/tif"
          when 9 then "image/png"
          when 10 then "smil"
          else "unknown"
        size: Number(t[3])

      type: switch Number(tokens[0])
        when 0 then "received"
        when 1 then "sent"
        when 2 then "unsent"
        else "unknown"
      sender   : tokens[1]
      to       : tokens[2].split(";")
      cc       : tokens[3].split(";")
      bcc      : tokens[4].split(";")
      datetime : Date(tokens[5])
      subject  : tokens[6]
      size     : Number(tokens[7])
      files    : files

  pushMMS: ->
    @invoke
      command: "AT+CMMSSEND"
      timeout: 200000

  requestUSSD: (ussd) ->
    @invoke "AT+CUSD=1,\"#{ussd}\""


module.exports = SimCom