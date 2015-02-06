
/*

SIM900
https://github.com/semencov/rpi-sim900

Copyright (c) 2015 Yuri Sementsov
Licensed under the MIT license.
 */

(function() {
  'use strict';
  var DEBUG, EventEmitter, Packetizer, Postmaster, SIM900, debug, serialport, use, util;

  util = require("util");

  serialport = require("serialport");

  EventEmitter = require("events").EventEmitter;

  Packetizer = require("./packetizer");

  Postmaster = require("./postmaster");

  DEBUG = false;

  SIM900 = (function() {
    function SIM900(device, options) {
      if (options == null) {
        options = {};
      }
      if (!options.lineEnd) {
        options.lineEnd = "\n";
      }
      if (!options.baudrate) {
        options.baudrate = 115200;
      }
      this.options = options;
      this.device = device;
      this.uart = new serialport.SerialPort(this.device, {
        baudrate: this.options.baudrate,
        parser: serialport.parsers.raw
      });
      this.opened = false;
      this.emissions = [];
      this.isCalling = false;
      this.isRinging = false;
      this.isBusy = false;
      this.packetizer = new Packetizer(this.uart, this.options.lineEnd, ["UNDER-VOLTAGE WARNNING"], true);
      this.packetizer.packetize();
      this.postmaster = new Postmaster(this.packetizer, ["OK", "ERROR", "> ", "DOWNLOAD"], null, null, DEBUG);
      return;
    }

    util.inherits(SIM900, EventEmitter);

    SIM900.prototype.connect = function(callback, rep, reps) {
      var patience, self;
      self = this;
      rep = rep || 0;
      reps = reps || 5;
      patience = 1000;
      this.uart.on('open', function() {
        self.execute("AT", patience, function(err, data) {
          if (!err) {
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
        }, [["AT", "\\x00AT", "\u0000AT", "OK"], ["OK"], 1]);
      });
    };

    SIM900.prototype.execute = function(message, patience, callback, alternate) {
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
      this.execute("ATA", 10000, function(err, data) {
        if (!err) {
          self.inACall = true;
        }
        callback(err, data);
      });
    };

    SIM900.prototype.executeBatch = function(messages, patiences, replies, callback) {
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
            console.log("execute sending", messages[0]);
          }
          self.execute(messages[0], patiences[0], func, [[replies[0][0]], [replies[0][replies[0].length - 1]]]);
          if (func === _intermediate) {
            self.once("_intermediate", function(correct) {
              if (correct) {
                self.executeBatch(messages.slice(1), patiences.slice(1), replies.slice(1), callback);
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
        this.execute("ATD" + number + ";", 1000 * 60 * 60 * 24 * 365, function(err, data) {
          this.inACall = false;
          callback(err, data);
        });
      }
    };

    SIM900.prototype.hangUp = function(callback) {
      var self;
      self = this;
      this.execute("ATH", 100000, function(err, data) {
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
      this.execute("AT+CMGR=" + index + "," + mode, 10000, function(err, message) {
        if (remove === 1) {
          self.execute("AT+CMGD=" + index, 10000);
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
        this.executeBatch(commands, patiences, replies, function(errr, data) {
          var correct, err, id;
          correct = !errr && data[0] === message && data[1] === "> ";
          id = -1;
          err = errr || new Error("Unable to send SMS");
          if (correct) {
            self.execute(new Buffer([0x1a]), 10000, (function(err, data) {
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

    SIM900.prototype.close = function() {
      this.uart.close();
    };

    return SIM900;

  })();

  use = function(hardware, options, callback) {
    var radio;
    if (options == null) {
      options = {};
    }
    if (callback == null) {
      callback = (function() {});
    }
    radio = new SIM900(hardware, options);
    radio.connect(callback);
    return radio;
  };

  debug = function(thing) {
    if (DEBUG) {
      console.log(thing);
    }
  };

  module.exports.use = use;

  module.exports.SIM900 = SIM900;

}).call(this);
