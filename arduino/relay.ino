/*
#===================================================================#
# Program => relay.ino (Arduino Sketch)                 version 1.0 #
#===================================================================#
# Autor         => Fernando "El Pop" Romo        (pop@cofradia.org) #
# Creation date => 11/may/2013                                      #
#-------------------------------------------------------------------#
# Info => This program control relays to turn on|off electric       #
#         circuits.                                                 #
#         Use Digital Pins 4 to 11 of Arduino UNO R3 and take the   #
#         commands from the USB.                                    #
#-------------------------------------------------------------------#
# This code are released under the GPL 3.0 License. Any change must #
# be report to the author                                           #
#                  (c) 2013 - Fernando Romo                         #
#-------------------------------------------------------------------#
*/
 
/* Init the board on Power On or serial connection */
void setup() {
   // initialize serial:
   Serial.begin(57600);
   // make the pins outputs:
   for (int i = 4; i <= 11; i++){
       pinMode(i, OUTPUT);
       // Turn off the signals to relays
       digitalWrite(i, HIGH);
   }
   Serial.print("\n");
   Status();
}
 
/* Send the state of the relays (on|off) */
void Status() {
     Serial.print("Status");
     for (int i = 4; i < 12; i++){
         if (digitalRead(i) == LOW) {
             Serial.print("|on");
          }
          else {
             Serial.print("|off");
          }
     }                 
     Serial.print("\n");
}
 
/* Turn off all the relays */
void All_On() {
    for (int i = 4; i <= 11; i++){
        digitalWrite(i, LOW);
    }
    Serial.print("all|on\n");
}
 
/* Turn off all the relays */
void All_Off() {
    for (int i = 4; i <= 11; i++){
        digitalWrite(i, HIGH);
    }
    Serial.print("all|off\n");
}
 
/* Turn ON a OFF relay and turn OFF and ON one*/
void Change_State (int digital_port) {
    if (digitalRead(digital_port+3) == HIGH) {
        digitalWrite((digital_port+3), LOW);
        Serial.print(digital_port);
        Serial.print("|on\n");
     }
     else {
         digitalWrite((digital_port+3), HIGH);
         Serial.print(digital_port);
         Serial.print("|off\n");
     }
}
 
/* Sequence to test the relays */
void Test() {
    Serial.print("test|on\n");
    All_Off();
    for (int i = 1; i <= 8; i++) {
        Change_State(i);
        delay(1000);
        Change_State(i);
    }
    delay(1000);
    for (int x = 1; x <= 2; x++) {
        for (int i = 1; i <= 8; i++) {
            Change_State(i);
            delay(1000);
        }
    }
    All_On();
    delay(1000);
    All_Off();    
    Serial.print("test|off\n");
}
 
/****************
 * Main program *
 ****************/
void loop() // run over and over
{
   while (Serial.available() > 0) {
       int sw = Serial.parseInt();
       if ((Serial.read() == '\n') ||
           (Serial.read() == '\r') )  {
           switch(sw) {
               case 0:
                   All_Off();
                   break;
               case 9:
                   All_On();
                   break;
               case 7828: // STAT
                   Status();
                   break;
               case 8378: // TEST
                   Test();
                   break;
               default:
                   if ((sw > 0) && (sw < 9)) {
                       Change_State(sw);
                   }
           }
       }
   }
}
/* End of program */