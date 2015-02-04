var modem = require('./lib/gsm')('/dev/ttyUSB0');

modem.on("error", function(error) {
  console.log(error);
});
modem.open()