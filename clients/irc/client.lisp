#|
 This file is a part of Colleen
 (c) 2015 Shirakumo http://tymoon.eu (shinmera@tymoon.eu)
 Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

(in-package #:org.shirakumo.colleen.clients.irc)

(defvar *send-length-limit* 512)

(define-consumer client (server-client user-client)
  ((nickname :initarg :nickname :accessor nickname)
   (username :initarg :username :accessor username)
   (password :initarg :password :accessor password)
   (realname :initarg :realname :accessor realname)
   (intended-nickname :initarg :intended-nickname :accessor intended-nickname)
   (socket :initform NIL :accessor socket)
   (timeout :initarg :timeout :accessor timeout)
   (last-pong :initform 0 :accessor last-pong)
   (read-thread :initform NIL :accessor read-thread)
   (services :initarg :services :accessor services))
  (:default-initargs
   :nickname (machine-instance)
   :username (machine-instance)
   :password NIL
   :realname (machine-instance)
   :port 6667
   :timeout 60
   :services :unknown))

(defmethod initialise-instance :after ((client client) &key)
  (unless (slot-boundp client 'intended-nickname)
    (setf (intended-nickname) (nickname client))))

(defmethod client-connected-p ((client client))
  (and (socket client)
       (usocket:socket-stream (socket client))
       (open-stream-p (usocket:socket-stream (socket client)))))

(defmethod initiate-connection ((client client))
  (with-slots (nickname username password realname host port socket read-thread) client
    (setf socket (usocket:socket-connect host port))
    (unless (and read-thread (bt:thread-alive-p read-thread))
      (setf read-thread (bt:make-thread (lambda () (handle-connection client)))))
    (when password (irc:pass client password))
    (irc:nick client nickname)
    (irc:user client username 0 "*" realname))
  client)

(defmethod close-connection ((client client))
  (with-slots (socket read-thread) client
    (when (open-stream-p (usocket:socket-stream socket))
      (irc:quit client))
    (when (and read-thread (bt:thread-alive-p read-thread) (not (eql (bt:current-thread) read-thread)))
      (bt:interrupt-thread read-thread (lambda () (invoke-restart 'abort)))
      (setf read-thread NIL))
    (usocket:socket-close socket)
    (setf socket NIL))
  client)

(defmethod send-connection ((client client) message)
  ;; FIXME: multithread
  (let ((stream (usocket:socket-stream (socket client)))
        (message (format NIL "~a~c~c" message #\Return #\Linefeed)))
    (when (< *send-length-limit* (length (babel:string-to-octets message :encoding (encoding client))))
      (warn 'message-too-long-warning :message message))
    (write-string message stream)
    (finish-output stream))
  client)

(defmethod handle-connection ((client client))
  (with-simple-restart (abort "Exit the connection handling.")
    (handler-bind (((or usocket:ns-try-again-condition 
                        usocket:timeout-error 
                        usocket:shutdown-error
                        usocket:connection-reset-error
                        usocket:connection-aborted-error
                        cl:end-of-file)
                     (lambda (err)
                       (v:error :colleen.client.irc.connection err)
                       (handle-connection-failure client)
                       (invoke-restart 'continue)))
                   (message-parse-error
                     (lambda (err)
                       (v:error :colleen.client.irc.connection "Parse error: ~a" err)
                       (invoke-restart 'continue)))
                   (unknown-message-event-warning
                     (lambda (err)
                       (v:warn :colleen.client.irc.connection "Parse error: ~a" err))))
      (loop (with-simple-restart (continue "Continue reading messages.")
              (setf (last-pong client) (get-universal-time))
              (loop for message = (read-connection client)
                    for events = (when (and message (string/= message ""))
                                   (parse-reply client message))
                    do (dolist (event events)
                         (deeds:issue event *event-loop*))
                       (loop for input-available = (nth-value 1 (usocket:wait-for-input (socket client) :timeout 1))
                             until input-available
                             do (ping-connection client)))))))
  client)

(defmethod handle-connection-failure ((client client))
  (v:info :colleen.client.irc.connection "~a Closing connection due to failure." client)
  (handler-case (close-connection client)
    (error (err)
      (v:log :error :colleen.client.irc.connection err)))
  (sleep 5) ;; Eventually write a backoff
  (v:info :colleen.client.irc.connection "~a Attempting to recover from failure." client)
  (initiate-connection client))

(defmethod read-connection ((client client))
  (handler-bind (#+sbcl (sb-int:stream-decoding-error
                          (lambda (err)
                            (v:log :warning :colleen.clients.irc.connection err)
                            (invoke-restart 'sb-int:attempt-resync))))
    (with-output-to-string (out)
      ;; Slow character by character copy, but since we have to do
      ;; CRLF detection portably, we cannot use READ-LINE.
      (loop with stream = (usocket:socket-stream (socket client))
            for char = (read-char stream) 
            do (case char
                 (#\Return
                  (let ((next (read-char stream)))
                    (if (eql next #\Newline)
                        (return)
                        (unread-char char stream))))
                 (T (write-char char out)))))))

(define-handler (client ping irc:rpl-ping) (client ev server other-server)
  :match-consumer client
  (setf (last-pong client) (get-universal-time))
  (irc:pong client server other-server))

(define-handler (client pong irc:rpl-pong) (client ev)
  :match-consumer client
  (setf (last-pong client) (get-universal-time)))

(defmethod ping-connection ((client client))
  (let ((since-pong (- (get-universal-time) (last-pong client))))
    (when (< (timeout client) since-pong)
      (error 'client-timeout-error :client client))
    (when (< (* (timeout client) 2/3) since-pong)
      (v:warn :colleen.clients.irc.connection "No pong reply in ~s seconds." since-pong))
    (when (< (* (timeout client) 1/5) since-pong)
      (irc:ping client (host client)))))

(define-handler (client nick-change irc:rpl-nick) (client ev sender nickname)
  :match-consumer client
  (when (string-equal sender (nickname client))
    (v:info :colleen.clients.irc.connection "Detected nick change from ~s to ~s." sender nickname)
    (setf (nickname client) nickname)))

(define-handler (client yank-nick irc:rpl-quit) (client ev sender)
  :match-consumer client
  (when (and (string-equal sender (intended-nickname client))
             (not (string-equal sender (nick client))))
    (v:info :colleen.clients.irc.connection "Detected nick drop for our intended nick ~s." sender)
    (irc:nick client sender)))

(defmethod authenticate (nick (client client))
  (case (services client)
    (:unknown
     NIL)
    (:anope
     (with-response
         (irc:privmsg :receivers "NickServ" :message (format NIL "STATUS ~a" nick) :client client)
         (irc:rpl-notice ev message)
         (:filter '(eql 0 (search "STATUS" message))
          :timeout 5)
       (cl-ppcre:register-groups-bind (status-nick code) ("^STATUS ([^ ]+) (\\d)" message)
         (and (string= nick status-nick)
              (string= code "3")))))
    ((NIL)
     T)))
