
/*
SIM900
https://github.com/semencov/sim900
Copyright (c) 2015 Yuri Sementsov
Licensed under the MIT license.
 */
'use strict';
var DEBUG, EventEmitter, Packetizer, Postmaster, SIM900, SerialPort, debug, util;

util = require("util");

EventEmitter = require("events").EventEmitter;

Packetizer = require("./packetizer");

Postmaster = require("./postmaster");

SerialPort = require("serialport").SerialPort;

DEBUG = true;

SIM900 = (function() {
  SIM900.prototype.commands = {
    LAST_COMMAND: "A/",
    ANSWER: "ATA",
    DIAL: "ATD",
    CALL_BY_NUMBER: "ATD><N>",
    CALL_BY_FIELD: "ATD><STR>",
    REDIAL: "ATDL",
    DISCONNECT: "ATH",
    DISCONNECT_VOICE: "AT+HVOIC",
    PULSE_DIALLING: "ATP",
    TONE_DIALING: "ATT",
    INFO: "ATI",
    CONFIG: "AT&V",
    LIST: "AT+GCAP",
    MANUFACTURER: "AT+GMI",
    MODEL: "AT+GMM",
    REVISION: "AT+GMR",
    GLOBAL: "AT+GOI",
    SERIAL: "AT+GSN",
    SET_ECHO_MODE: "ATE",
    SET_MONITOR_SPEAKER_LOUDNESS: "ATL",
    SET_MONITOR_SPEAKER_MODE: "ATM",
    SET_COMMAND_MODE: "+++",
    SET_DATA_MODE: "ATO",
    SET_RESULT_MODE: "ATQ",
    SET_RESULT_FORMAT: "ATX",
    SET_DCD_MODE: "AT&C",
    SET_DTR_MODE: "AT&D",
    SELECT_PROFILE: "ATZ",
    SAVE_PROFILE: "AT&W",
    SET_DEFAULTS: "AT&F",
    SET_TA_RESPONSE_FORMAT: "ATV",
    SET_ATS0: "ATS0",
    SET_ATS3: "ATS3",
    SET_ATS4: "ATS4",
    SET_ATS5: "ATS5",
    SET_ATS7: "ATS7",
    SET_ATS8: "ATS8",
    SET_ATS10: "ATS10",
    SET_TETA_CONTROL_CHARACTER_FRAMING: "AT+ICF",
    SET_TETA_LOCAL_DATA_FLOW_CONTROL: "AT+IFC",
    SET_TETA_FIXED_LOCAL_RATE: "AT+IPR"
  };

  function SIM900(options) {
    if (options == null) {
      options = "/dev/ttyS0";
    }
    if (typeof options === 'string') {
      options = {
        device: options
      };
    }
    this.serialport = new SerialPort(options.device, {
      baudrate: options.baudrate || 57600
    });
    this.inACall = false;
    this.emissions = [];
    this.powered = null;
    this.packetizer = new Packetizer(this.serialport);
    this.packetizer.packetize();
    this.postmaster = new Postmaster(this.packetizer, ["OK", "ERROR", "> ", "DOWNLOAD"], null, null, DEBUG);
    return;
  }

  util.inherits(SIM900, EventEmitter);

  SIM900.prototype._establishContact = function(callback, rep, reps) {
    var checkIfWeContacted, patience, self;
    self = this;
    rep = rep || 0;
    reps = reps || 5;
    patience = 1000;
    this._txrx("AT", patience, (checkIfWeContacted = function(err, data) {
      var tryAgainAfterToggle;
      if (err && err.type === "timeout" && rep < reps) {
        self.togglePower(tryAgainAfterToggle = function() {
          self._establishContact(callback, rep + 1, reps);
        });
      } else if (!err) {
        self.emit("ready", data);
        if (callback) {
          callback(err, self);
        }
      } else {
        err = new Error("Could not connect to SIM900 Module");
        setImmediate(function() {
          self.emit("error", err);
        });
        if (callback) {
          callback(err, self);
        }
      }
    }), [["AT", "\\x00AT", "\u0000AT", "OK"], ["OK"], 1]);
  };

  SIM900.prototype._txrx = function(message, patience, callback, alternate) {
    message = message || "AT";
    patience = patience || 250;
    callback = callback || (function(err, arg) {
      if (err) {
        debug("err:\n", err);
      } else {
        debug("reply:\n", arg);
      }
    });
    alternate = alternate || null;
    patience = Math.max(patience, 100);
    this.postmaster.send(message, patience, callback, alternate);
  };

  SIM900.prototype.answerCall = function(callback) {
    var self;
    self = this;
    this._txrx("ATA", 10000, function(err, data) {
      if (!err) {
        self.inACall = true;
      }
      callback(err, data);
    });
  };

  SIM900.prototype._chain = function(messages, patiences, replies, callback) {
    var func, self, _intermediate;
    self = this;
    if (messages.length !== patiences.length || messages.length !== replies.length) {
      callback(new Error("Array lengths must match"), false);
    } else {
      _intermediate = function(err, data) {
        var correct, i;
        correct = !err;
        if (replies[0]) {
          i = 0;
          while (i < data.length) {
            correct = correct && ([data[i], "\\x00" + data[i], "\u0000" + data[i]].indexOf(replies[0][i]) > -1);
            if (DEBUG) {
              console.log("data array", [data[i], "\\x00" + data[i], "\u0000" + data[i]]);
              console.log("replies", replies);
              console.log("replies[0]", replies[0], replies[0][i]);
            }
            i++;
          }
        }
        self.emit("_intermediate", correct);
      };
      if (messages.length > 0) {
        func = (messages.length === 1 ? callback : _intermediate);
        if (DEBUG) {
          console.log("_txrx sending", messages[0]);
        }
        self._txrx(messages[0], patiences[0], func, [[replies[0][0]], [replies[0][replies[0].length - 1]]]);
        if (func === _intermediate) {
          self.once("_intermediate", function(correct) {
            if (correct) {
              self._chain(messages.slice(1), patiences.slice(1), replies.slice(1), callback);
            } else {
              self.postmaster.forceClear();
              if (callback) {
                callback(new Error("Chain broke on " + messages[0]), false);
              }
            }
          });
        }
      }
    }
  };

  SIM900.prototype.dial = function(number, callback) {
    if (this.inACall) {
      callback(new Error("Currently in a call"), []);
    } else if (!number || !String(number).length) {
      callback(new Error("Did not specify a phone number"), []);
    } else {
      this.inACall = true;
      this._txrx("ATD" + number + ";", 1000 * 60 * 60 * 24 * 365, function(err, data) {
        this.inACall = false;
        callback(err, data);
      });
    }
  };

  SIM900.prototype.hangUp = function(callback) {
    var self;
    self = this;
    this._txrx("ATH", 100000, function(err, data) {
      self.inACall = false;
      callback(err, data);
    });
  };

  SIM900.prototype._checkEmissions = function() {
    var self;
    self = this;
    this.postmaster.on("unsolicited", function(data) {
      var sent;
      sent = false;
      self.emissions.forEach(function(beginning) {
        if (data.indexOf(beginning) === 0) {
          self.emit(beginning, data);
          sent = true;
        }
      });
      if (!sent) {
        self.emit("unsolicited", data);
      }
    });
  };

  SIM900.prototype.emitMe = function(beginnings) {
    var self;
    self = this;
    beginnings.forEach(function(beginning) {
      self.emissions.push(beginning);
    });
    if (this.emissions.length === beginnings.length) {
      this._checkEmissions();
    }
  };

  SIM900.prototype.readSMS = function(index, mode, remove, callback) {
    var next, self;
    if (typeof callback === "undefined") {
      callback = remove;
      remove = 0;
    }
    next = next || remove;
    self = this;
    this._txrx("AT+CMGR=" + index + "," + mode, 10000, function(err, message) {
      if (remove === 1) {
        self._txrx("AT+CMGD=" + index, 10000);
      }
      callback(err, message);
    });
  };

  SIM900.prototype.sendSMS = function(number, message, callback) {
    var commands, patiences, replies, self;
    if (!number || !number.length) {
      callback(new Error("Did not specify a phone number"), null);
    } else {
      self = this;
      message = message || "text from a Tessel";
      commands = ["AT+CMGF=1", "AT+CMGS=\"" + number + "\"", message];
      patiences = [2000, 5000, 5000];
      replies = [["AT+CMGF=1", "OK"], ["AT+CMGS=\"" + number + "\"", "> "], [message, "> "]];
      this._chain(commands, patiences, replies, function(errr, data) {
        var correct, err, id;
        correct = !errr && data[0] === message && data[1] === "> ";
        id = -1;
        err = errr || new Error("Unable to send SMS");
        if (correct) {
          self._txrx(new Buffer([0x1a]), 10000, (function(err, data) {
            if (data && data[0] && data[0].indexOf("+CMGS: ") === 0 && data[1] === "OK") {
              id = parseInt(data[0].slice(7), 10);
              err = null;
            }
            if (callback) {
              callback(err, [id]);
            }
          }), [["+CMGS: ", "ERROR"], ["OK", "ERROR"], 1]);
        } else {
          if (callback) {
            callback(err, [id]);
          }
        }
      });
    }
  };

  SIM900.prototype.togglePower = function(callback) {
    var self;
    self = this;
    debug("toggling power...");
    self.power.high();
    setTimeout((function() {
      self.power.low();
      setTimeout((function() {
        self.power.high();
        setTimeout((function() {
          self.emit("powerToggled");
          debug("done toggling power");
          if (callback) {
            callback();
          }
        }), 5000);
      }), 1500);
    }), 100);
  };

  SIM900.prototype.disable = function() {
    this.uart.disable();
  };

  return SIM900;

})();

debug = function(thing) {
  if (DEBUG) {
    console.log(thing);
  }
};

module.exports = SIM900;
