#|
 This file is a part of Maiden
 (c) 2016 Shirakumo http://tymoon.eu (shinmera@tymoon.eu)
 Author: Nicolas Hafner <shinmera@tymoon.eu>
|#

(in-package #:maiden-user)
(defpackage #:maiden-throttle
  (:nicknames #:org.shirakumo.maiden.agents.throttle)
  (:use #:cl #:maiden #:maiden-storage #:maiden-commands #:maiden-client-entities)
  ;; throttle.lisp
  (:export
   #:throttle
   #:attempts
   #:time-frame
   #:cooldown-function
   #:cooldown-step
   #:cooldown-max
   #:records
   #:record
   #:attempts
   #:timestamp
   #:timeout
   #:clear-tax
   #:tax
   #:view-config
   #:set-config
   #:clear-tax))
