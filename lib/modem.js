(function() {
  var EventEmitter, Modem, Q, buffertools, errorCodes, fs, init, instances, log, serialport, util,
    __slice = [].slice;

  fs = require('fs');

  util = require('util');

  serialport = require('serialport');

  buffertools = require('buffertools');

  Q = require('q');

  EventEmitter = require('events').EventEmitter;

  log = null;

  instances = {};

  errorCodes = {
    '0': "phone failure",
    '1': "no connection to phone",
    '2': "phone-adaptor link reserved",
    '3': "operation not allowed",
    '4': "operation not supported",
    '5': "PH-SIM PIN required",
    '6': "PH-FSIM PIN required",
    '7': "PH-FSIM PUK required",
    '10': "SIM not inserted",
    '11': "SIM PIN required",
    '12': "SIM PUK required",
    '13': "SIM failure",
    '14': "SIM busy",
    '15': "SIM wrong",
    '16': "incorrect password",
    '17': "SIM PIN2 required",
    '18': "SIM PUK2 required",
    '20': "memory full",
    '21': "invalid index",
    '22': "not found",
    '23': "memory failure",
    '24': "text string too long",
    '25': "invalid characters in text string",
    '26': "dial string too long",
    '27': "invalid characters in dial string",
    '30': "no network service",
    '31': "network timeout",
    '32': "network not allowed - emergency calls only",
    '40': "network personalization PIN required",
    '41': "network personalization PUK required",
    '42': "network subset personalization PIN required",
    '43': "network subset personalization PUK required",
    '44': "service provider personalization PIN required",
    '45': "service provider personalization PUK required",
    '46': "corporate personalization PIN required",
    '47': "corporate personalization PUK required",
    '100': "Unknown",
    '103': "illegal MS",
    '106': "illegal ME",
    '107': "GPRS services not allowed",
    '111': "PLMN not allowed",
    '112': "location area not allowed",
    '113': "roaming not allowed in this location area",
    '132': "service option not supported",
    '133': "requested service option not subscribed",
    '134': "service option temporarily out of order",
    '148': "unspecified GPRS error",
    '149': "PDP authentication failure",
    '150': "invalid mobile class",
    '300': "ME failure",
    '301': "SMS ME reserved",
    '302': "Operation not allowed",
    '303': "Operation not supported",
    '304': "Invalid PDU mode",
    '305': "Invalid text mode",
    '310': "SIM not inserted",
    '311': "SIM pin necessary",
    '312': "PH SIM pin necessary",
    '313': "SIM failure",
    '314': "SIM busy",
    '315': "SIM wrong",
    '316': "SIM PUK required",
    '317': "SIM PIN2 required",
    '318': "SIM PUK2 required",
    '320': "Memory failure",
    '321': "Invalid memory index",
    '322': "Memory full",
    '330': "SMSC address unknown",
    '331': "No network",
    '332': "Network timeout",
    '500': "Unknown",
    '512': "SIM not ready",
    '513': "Unread records on SIM",
    '514': "CB error unknown",
    '515': "PS busy",
    '528': "Invalid (non-hex) chars inPDU",
    '529': "Incorrect PDU length",
    '530': "Invalid MTI",
    '531': "Invalid (non-hex) chars in address",
    '532': "Invalid address (no digits read)",
    '533': "Incorrect PDU length (UDL)",
    '534': "Incorrect SCA length",
    '536': "Invalid First Octet (should be 2 ore 34)",
    '537': "Invalid Command type",
    '538': "SRR bit not set",
    '539': "SRR bit set",
    '540': "Invalid User Data Header IE"
  };

  Modem = (function() {
    var fetchExecution, isErrorCode, isResultCode, processLine, processLines, processResponse, processUnboundLine, readBuffer, unboundExprs;

    function Modem(device, options) {
      if (options == null) {
        options = {};
      }
      if (!options.lineEnd) {
        options.lineEnd = "\r\n";
      }
      if (!options.baudrate) {
        options.baudrate = 115200;
      }
      if (options.log != null) {
        log = fs.createWriteStream(options.log);
      }
      this.options = options;
      this.device = device;
      this.tty = null;
      this.opened = false;
      this.lines = [];
      this.executions = [];
      this.isCalling = false;
      this.isRinging = false;
      this.isBusy = false;
      this.buffer = new Buffer(0);
      buffertools.extend(this.buffer);
      return;
    }

    util.inherits(Modem, EventEmitter);

    Modem.prototype.open = function(timeout) {
      var self;
      self = this;
      if (self.opened) {
        self.emit("open");
        return;
      }
      timeout = timeout || 5000;
      this.tty = new serialport.SerialPort(this.device, {
        baudrate: this.options.baudrate,
        parser: serialport.parsers.raw
      });
      this.tty.on("open", function() {
        this.on("data", function(data) {
          self.buffer = Buffer.concat([self.buffer, data]);
          readBuffer.call(self);
        });
        self.execute("AT", timeout).then(function() {
          self.emit("open");
        }).fail(function(error) {
          self.emit("error", error);
        }).done();
      });
      this.tty.on("close", function() {
        self.opened = false;
        self.emit("close");
      });
      this.tty.on("error", function(err) {
        self.emit("error", err);
      });
      this.opened = true;
    };

    Modem.prototype.close = function() {
      this.tty.close();
      this.tty = null;
      instances[this.device] = null;
      delete instances[this.device];
    };

    Modem.prototype.write = function(data, callback) {
      this.tty.write(data, callback);
    };

    Modem.prototype.writeAndWait = function(data, callback) {
      var self;
      self = this;
      this.write(data, function() {
        self.tty.drain(callback);
      });
    };

    Modem.prototype.execute = function() {
      var args, callback, command, defer, pdu, response, timeout, _ref;
      command = arguments[0], args = 2 <= arguments.length ? __slice.call(arguments, 1) : [];
      if (command == null) {
        return;
      }
      callback = typeof args.slice(-1)[0] === 'function' ? args.pop() : null;
      pdu = (_ref = typeof args.slice(-1)[0]) === 'boolean' || _ref === 'object' ? args.pop() : false;
      response = typeof args.slice(-1)[0] === 'string' ? args.pop() : null;
      timeout = typeof args.slice(-1)[0] === 'number' ? args.pop() : false;
      defer = Q.defer();
      defer.execution = {
        exec: command,
        response: response,
        callback: callback,
        pdu: pdu,
        timeout: timeout
      };
      if (this.executions.push(defer) === 1) {
        fetchExecution.call(this);
      }
      return defer.promise;
    };

    fetchExecution = function() {
      var cmd, defer, execution, _ref;
      defer = this.executions[0];
      if (!defer) {
        return;
      }
      execution = defer.execution;
      cmd = (_ref = execution.exec) != null ? _ref.split("\r", 1).shift() : void 0;
      this.write("" + cmd + "\r");
      if (execution.timeout) {
        defer.timer = setTimeout(function() {
          defer.reject(new Error("Command '" + execution.exec + "' failed by timed out"));
        }, execution.timeout);
      }
    };

    readBuffer = function() {
      var line, lineEndLength, lineEndPosition, newBuffer, self;
      self = this;
      lineEndLength = self.options.lineEnd.length;
      lineEndPosition = buffertools.indexOf(self.buffer, self.options.lineEnd);
      if (lineEndPosition === -1) {
        if (this.buffer.length === 2 && this.buffer.toString() === "> ") {
          processLine.call(this, this.buffer.toString());
        }
        return;
      }
      line = this.buffer.slice(0, lineEndPosition);
      newBuffer = new Buffer(this.buffer.length - lineEndPosition - lineEndLength);
      this.buffer.copy(newBuffer, 0, lineEndPosition + lineEndLength);
      this.buffer = newBuffer;
      processLine.call(this, line.toString("ascii"));
      process.nextTick(readBuffer.bind(this));
    };

    processUnboundLine = function(line) {
      var i, m, u;
      i = 0;
      while (i < unboundExprs.length) {
        u = unboundExprs[i];
        m = line.match(u.expr);
        if (m) {
          u.func && u.func.call(this, m);
          if (!u.unhandle) {
            this.emit("urc", m, u.expr);
            return true;
          }
        }
        i++;
      }
      return false;
    };

    processLine = function(line) {
      log && log.write("" + line + "\n");
      if (line.substr(0, 2) === "AT") {
        return;
      }
      if (processUnboundLine.call(this, line)) {
        return;
      }
      this.lines.push(line);
      processLines.call(this);
    };

    isResultCode = function(line) {
      return /(^OK|ERROR|BUSY|DATA|NO ANSWER|NO CARRIER|NO DIALTONE|OPERATION NOT ALLOWED|COMMAND NOT SUPPORT|\+CM[ES]|> $)|(^CONNECT( .+)*$)/i.test(line);
    };

    isErrorCode = function(line) {
      return /^(\+CM[ES]\s)?ERROR(\:.*)?|BUSY|NO ANSWER|NO CARRIER|NO DIALTONE|OPERATION NOT ALLOWED|COMMAND NOT SUPPORT$/i.test(line);
    };

    processLines = function() {
      if (!this.lines.length) {
        return;
      }
      if (!isResultCode(this.lines[this.lines.length - 1])) {
        return;
      }
      if (this.lines[0].trim() === "") {
        this.lines.shift();
      }
      processResponse.call(this);
      this.lines = [];
    };

    processResponse = function() {
      var cmd, defer, error, exec, execution, m, response, responseCode, _ref;
      responseCode = this.lines.pop();
      defer = this.executions[0];
      execution = defer && defer.execution;
      exec = (_ref = execution.exec) != null ? _ref.split("\r") : void 0;
      cmd = exec.shift();
      if (responseCode === "> ") {
        if (execution && exec.length) {
          this.write("" + (exec.shift()) + "\r\x1A");
        }
        return;
      }
      if (responseCode.match(/^CONNECT( .+)*$/i)) {
        if (execution && execution.pdu) {
          this.write(execution.pdu);
          execution.pdu = null;
        }
        return;
      }
      if (defer) {
        this.executions.shift();
        response = {
          code: responseCode,
          command: cmd,
          lines: this.lines
        };
        if (execution.response) {
          response.success = responseCode.match(new RegExp("^" + execution.response + "$", 'i')) != null;
        }
        if (defer.timer) {
          clearTimeout(defer.timer);
          defer.timer = null;
        }
        if (isErrorCode(responseCode)) {
          error = new Error("" + cmd + " responsed error: '" + responseCode + "'");
          if (m = responseCode.match(/^\+CM[ES] ERROR\: (\d+)/)) {
            if (errorCodes[m[1]] != null) {
              error = errorCodes[m[1]];
            }
          }
          error.code = responseCode;
          if (typeof execution.callback === "function") {
            execution.callback(error, null);
          }
          defer.reject(error);
          return;
        }
        if (typeof response['success'] !== 'undefined' && !response['success']) {
          error = new Error("" + cmd + " missed the awaited response. Response was: " + responseCode);
          error.code = responseCode;
          if (typeof execution.callback === "function") {
            execution.callback(error, null);
          }
          defer.reject(error);
          return;
        }
        if (typeof execution.callback === "function") {
          execution.callback(null, response);
        }
        defer.resolve(response);
      }
      if (this.executions.length) {
        fetchExecution.call(this);
      }
    };

    unboundExprs = [
      {
        expr: /^NO CARRIER$/i,
        func: function(m) {
          if (this.isRinging) {
            this.isRinging = false;
            this.emit("end ring");
          }
          if (this.isCalling) {
            this.isCalling = false;
            this.emit("end call");
          }
        }
      }, {
        expr: /^OVER-VOLTAGE WARNNING$/i,
        func: function(m) {
          this.emit("over-voltage warnning");
        }
      }, {
        expr: /^RING$/i,
        func: function(m) {
          this.isRinging = true;
          this.emit("ring");
        }
      }, {
        expr: /^\+CMTI: (.+)$/i,
        func: function(m) {
          this.emit("new message", m[1]);
        }
      }, {
        expr: /^\+CPIN: (NOT .+)/i,
        unhandled: true,
        func: function(m) {
          this.emit("sim error", m[1]);
        }
      }, {
        expr: /^\+CUSD: (.+)$/i,
        func: function(m) {
          this.emit("ussd", m[1]);
        }
      }, {
        expr: /^\+CMGS: (.+)$/i,
        func: function(m) {}
      }, {
        unhandled: true,
        expr: /^\+CREG: (\d)$/i,
        func: function(m) {
          this.isBusy = false;
        }
      }
    ];

    return Modem;

  })();

  init = function(device, options) {
    device = device || "/dev/ttyAMA0";
    if (!instances[device]) {
      instances[device] = new Modem(device, options);
    }
    return instances[device];
  };

  module.exports = init;

  process.on('exit', function(code) {
    log && log.end();
  });

}).call(this);
