(in-package :shcl.utility)

(defmacro optimization-settings ()
  "Declaims standard optimization settings.

Put this at the top of every file!"
  `(declaim (optimize (speed 0) (safety 3) (space 0) (debug 3) (compilation-speed 0))))

(optimization-settings)

(defmacro define-once-global (name initform &body options)
  "Define a global variable.

The variable is initialized the first time it is accessed and is
initialized at most once.  Redefining the variable with
`define-once-global' will reset the variable to be uninitialized."
  (check-type name symbol)
  (unless (get name 'define-once-global-getter)
    (setf (get name 'define-once-global-getter) (gensym (symbol-name name))))
  (let* ((value (gensym "VALUE"))
         (set (gensym "SET"))
         (getter (get name 'define-once-global-getter))
         (setter (get name 'define-once-global-setter))
         (setter-value (gensym "SETTER-VALUE"))
         (lock (gensym "LOCK"))
         (documentation (second (find :documentation options :key 'car)))
         (no-lock (second (find :no-lock options :key 'car)))
         (read-only (second (find :read-only options :key 'car)))
         (lock-form (if no-lock '(progn) `(bordeaux-threads:with-lock-held (,lock)))))
    (when (and (not read-only) (not setter))
      (setf (get name 'define-once-global-setter) (gensym (concatenate 'string (symbol-name name) "-SETTER")))
      (setf setter (get name 'define-once-global-setter)))

    (check-type documentation (or null string))
    (when documentation
      (setf documentation (list documentation)))
    (unless (member no-lock '(nil t))
      (error ":no-lock option must have value nil or t"))
    (unless (member read-only '(nil t))
      (error ":read-only option must have value nil or t"))
    `(eval-when (:compile-toplevel :load-toplevel :execute)
       (let (,@(unless no-lock `((,lock (bordeaux-threads:make-lock ,(symbol-name name)))))
             ,value ,set)
         (defun ,getter ()
           ,@documentation
           (,@lock-form
            (unless ,set
              (setf ,value ,initform
                    ,set t))
            ,value))
         ,@(unless read-only
                   `((defun ,setter (,setter-value)
                       (,@lock-form
                        (setf ,value ,setter-value
                              ,set t)
                        ,setter-value))
                     (defsetf ,getter ,setter)))
         (define-symbol-macro ,name (,getter))))))

(defparameter *debug-stream* *error-output*
  "The stream where log lines are sent.")
(defparameter *debug-stream-lock* (make-lock)
  "The lock that protects `*debug-stream*'.")

(defparameter *log-levels*
  (alist-hash-table
   '((error . t)
     (warning . t)
     (status . t)))
  "The hash table that dictates which log levels are enabled and which
are not.")

(defun logging-enabled-p (level)
  "Returns t iff the given log level is enabled."
  (gethash level *log-levels*))

(defmacro debug-log (level message &rest format-args)
  "Emit a log line."
  (let ((level-val (gensym "LEVEL-VAL")))
    `(with-lock-held (*debug-stream-lock*)
       (let ((,level-val ,level))
         (when (logging-enabled-p ,level-val)
           (format *debug-stream* ,message ,@format-args)
           (fresh-line *debug-stream*))))))

(defstruct hook
  (functions (fset:empty-set)))

(defmacro define-hook (name &optional documentation)
  "Create a hook.

A hook is more or less an unordered collection of functions.  When the
hook is run with `run-hook', each function will be called once."
  `(defparameter ,name
     (make-hook)
     ,documentation))

(defun add-hook (hook function-symbol)
  "Add a function a function to a hook."
  (check-type hook hook)
  (check-type function-symbol symbol)
  (setf (hook-functions hook) (fset:with (hook-functions hook) function-symbol))
  hook)

(defun remove-hook (hook function-symbol)
  "Remove a function from a hook."
  (check-type hook hook)
  (check-type function-symbol symbol)
  (setf (hook-functions hook) (fset:less (hook-functions hook) function-symbol))
  hook)

(defun run-hook (hook)
  "Run each function in the provided hook."
  (fset:do-set (fn (hook-functions hook))
    (funcall fn)))

(define-hook *revival-hook*
  "This hook is run when the process starts.")

(defmacro on-revival (function-symbol)
  "When the process starts, call the named function."
  `(add-hook *revival-hook* ',function-symbol))

(defun observe-revival ()
  "The process has started!"
  (run-hook *revival-hook*))

(define-hook *dump-hook*
  "This hook is run when an executable is being prepared.

Note, it is as of yet undetermined whether this hook will run or not
for lisp compilers like ECL.")

(defmacro on-dump (function-symbol)
  "When saving an executable, call the named function."
  `(add-hook *dump-hook* ',function-symbol))

(defun observe-dump ()
  "We're saving an executable!"
  (run-hook *dump-hook*))

(defun %when-let (let-sym bindings body)
  (let ((block (gensym (format nil "WHEN-~A-BLOCK" (symbol-name let-sym)))))
    (labels
        ((transform (binding)
           (when (symbolp binding)
             (setf binding (list binding nil)))
           (destructuring-bind (variable &optional value) binding
             (let ((value-sym (gensym "VALUE")))
               (setf value `(let ((,value-sym ,value))
                              (if ,value-sym
                                  ,value-sym
                                  (return-from ,block))))
               (list variable value)))))
      `(block ,block
         (,let-sym ,(mapcar #'transform bindings)
           ,@body)))))

(defmacro when-let* (bindings &body body)
  "Establish bindings (like `let*' would).  If any variable is bound to
nil, then the whole `when-let*' short circuts and evaluates to nil."
  (%when-let 'let* bindings body))

(defmacro when-let (bindings &body body)
  "Establish bindings (like `let' would).  If any variable is bound to
nil, then the whole `when-let' short circuts and evaulates to nil."
  (%when-let 'let bindings body))

(define-condition required-argument-missing (error)
  ()
  (:documentation
   "A condition for indicating that a required argument was not provided."))

(defmacro required ()
  "This form always signals an error of type `required-argument-missing'."
  `(error 'required-argument-missing))

(defmacro try (exceptionable-form &body clauses)
  "A better version of `catch'.

When you use `catch', you can't distinguish between normal execution and a thrown value.  Sometimes that is desirable.  Other times, you might like to know the difference.  With `signal' and conditions, you have that flexibility.  However, the condition system is fairly heavyweight and thus isn't appropriate for all use cases.  The `try' macro attempts to bring some of the flexibility of `handler-case' to `catch' and tries to emulate the control-flow of a more traditional exception system.

Example:
(try
    (throw 'foobar (values 1 2 3))
  (foobar (x y z) (+ x y z))
  (baz (a) (frobnosticate a)))

It is unspecified what happens if one of the handler clauses throws a
tag named in a different clause."
  ;; We're going to do a slightly insane thing.  We're going to build
  ;; up a series of nested forms that look like this.
  ;; (multiple-value-call #'foo-handler
  ;;   (catch 'foo
  ;;     (return-from no-problem
  ;;       (multiple-value-call #'bar-handler
  ;;         (catch 'bar
  ;;           (return-from no-problem <...>))))))
  ;; If nothing is thrown, then the return-from form will execute.  If
  ;; something is thrown, then we bypass the return-from and call the
  ;; handler instead.  When the handler returns, its wrapping
  ;; return-from form will cause us to exit the try form altogether.
  (let ((no-problem (gensym "NO-PROBLEM"))
        labels-forms
        tag-label-alist)
    (dolist (clause clauses)
      (destructuring-bind (tag lambda-list &body body) clause
        (let ((label (gensym (symbol-name tag))))
          (push (cons tag label) tag-label-alist)
          (push `(,label ,lambda-list ,@body) labels-forms))))
    (setf labels-forms (nreverse labels-forms)
          tag-label-alist (nreverse tag-label-alist))

    (labels
        ((catch-form (tag-alist)
           (if (null tag-alist)
               exceptionable-form
               (let* ((head (car tag-alist))
                      (rest (cdr tag-alist))
                      (tag (car head))
                      (label (cdr head)))
                   `(multiple-value-call #',label
                      (catch ',tag
                        (return-from ,no-problem ,(catch-form rest))))))))
      `(block ,no-problem
         (labels (,@labels-forms)
           ,(catch-form tag-label-alist))))))

(defun make-extensible-vector
    (&key
       (initial-size 0)
       (initial-element nil initial-element-p)
       (initial-contents nil initial-contents-p)
       (element-type t)
       (fill-pointer t))
  "This function provides a quick way to make a single-dimensional,
adjustable array with a fill pointer."
  (cond
    ((and initial-element-p initial-contents-p)
     (error "Can't specify both initial-element and initial-contents"))

    ((not fill-pointer)
     (error "fill-pointer cannot be nil"))

    (initial-element-p
     (make-array initial-size :adjustable t :fill-pointer fill-pointer :initial-element initial-element :element-type element-type))

    (initial-contents-p
     (make-array initial-size :adjustable t :fill-pointer fill-pointer :initial-contents initial-contents :element-type element-type))

    (t
     (make-array initial-size :adjustable t :fill-pointer fill-pointer :element-type element-type))))

(defclass iterator ()
  ((compute
    :initarg :compute
    :documentation
    "A function that returns the next value."))
  (:documentation
   "This represents the most basic sort of iterator.  It can only go
forward."))

(defmacro make-iterator ((&key type) &body body)
  "Create an iterator.

The body of this macro will be executed each time the iterator needs
to produce a new value.  Within the body, the local macros `stop' and
`emit' can be used to indicate end of sequence or return a value.
After `stop' is evaluated, the iterator will not be called again.
Both `stop' and `emit' cause a control transfer out of the body of
`make-iterator'."
  (let ((stop-value (gensym "STOP-VALUE"))
        (compute (gensym "COMPUTE"))
        (compute-block (gensym "COMPUTE-BLOCK"))
        (value (gensym "VALUE"))
        (type-sym (gensym "TYPE-SYM")))
    `(let* ((,type-sym ,type))
       (macrolet ((emit (value)
                    (list 'return-from ',compute-block value))
                  (stop ()
                    '(return-from ,compute-block ',stop-value)))
         (labels ((,compute ()
                    (let ((,value (block ,compute-block ,@body)))
                      (cond ((eq ,value ',stop-value)
                             (values nil nil))

                            (t
                             (values ,value t))))))
           (make-instance (or ,type-sym 'iterator) :compute #',compute)
           ;; Now would be a good time to set the funcall function for
           ;; this iterator
           )))))

(defun iterate-iterator (iter)
  (with-slots (compute) iter
    (when (not (slot-boundp iter 'compute))
      (return-from iterate-iterator (values nil nil)))

    (multiple-value-bind (value more) (funcall compute)
      (unless more
        (slot-makunbound iter 'compute))
      (values value more))))

(defgeneric iterate-function (iterator))
(defmethod iterate-function ((iter iterator))
  #'iterate-iterator)

(defun next (iter)
  (funcall (iterate-function iter) iter))

(defmacro do-iterator ((value-sym iter &key result) &body body)
  (let ((iter-sym (gensym "ITER-SYM"))
        (more-sym (gensym "MORE-SYM"))
        (iter-fun (gensym "ITER-FUN")))
    `(let* ((,iter-sym ,iter)
            (,iter-fun (iterate-function ,iter-sym)))
       (loop
          (multiple-value-bind (,value-sym ,more-sym) (funcall ,iter-fun ,iter-sym)
            (unless ,more-sym
              (return ,result))
            ,@body)))))

(defun map-iterator (iter function &key type)
  (make-iterator (:type type)
    (multiple-value-bind (value more) (next iter)
      (unless more
        (stop))
      (emit (funcall function value)))))

(defun iterator-values (iter)
  (let ((vector (make-extensible-vector)))
    (do-iterator (value iter :result vector)
      (vector-push-extend value vector))))

(defclass lookahead-iterator ()
  ((compute
    :initform (cons t nil)
    :initarg :compute)
   (buffer
    :initform (cons 'tail 'tail)
    :initarg :buffer
    :type cons)))
(defmethod initialize-instance :after ((iter lookahead-iterator) &key)
  (with-slots (compute buffer) iter
    (unless (consp compute)
      (setf compute (cons t compute)))))

(defmethod update-instance-for-different-class :after ((old iterator) (new lookahead-iterator) &key)
  (declare (ignore old))
  (with-slots (compute) new
    (unless (consp compute)
      (setf compute (cons t compute))))
  ;; Now would be a good time to set the funcall function
  )

(defun make-iterator-lookahead (iterator)
  (check-type iterator iterator)
  (change-class iterator (find-class 'lookahead-iterator)))

(defun fork-lookahead-iterator (iter)
  (check-type iter lookahead-iterator)
  (with-slots (compute buffer) iter
    (make-instance (class-of iter) :compute compute :buffer buffer)))

(defun iterate-lookahead-iterator (iter)
  (with-slots (buffer compute) iter
    (when (and (eq (cdr buffer) 'tail)
               (not (cdr compute)))
      (return-from iterate-lookahead-iterator (values nil nil)))

    (cond ((eq (cdr buffer) 'tail)
           ;; Buffer is empty.  Add something to the back
           (multiple-value-bind (value more) (funcall (cdr compute))
             (cond (more
                    (let ((new-tail (cons 'tail 'tail)))
                      (setf (car buffer) value
                            (cdr buffer) new-tail
                            buffer (cdr buffer))))

                   (t
                    (setf (cdr compute) nil)))
             (values value more)))

          (t
           (let ((value (car buffer)))
             (setf buffer (cdr buffer))
             (values value t))))))

(defmethod iterate-function ((iter lookahead-iterator))
  (declare (ignore iter))
  #'iterate-lookahead-iterator)

(defun peek-lookahead-iterator (iter)
  (iterate-lookahead-iterator (fork-lookahead-iterator iter)))

(defun move-lookahead-to (iter-to-change model-iter)
  (with-slots ((b-compute compute)
               (b-buffer buffer))
      iter-to-change
    (with-slots ((a-compute compute)
                 (a-buffer buffer))
        model-iter
      (unless (eq a-compute b-compute)
        (error "These iterators aren't in the same family"))
      (setf b-buffer a-buffer)))
  (values))

(defun vector-iterator (vector &key type)
  (let ((index 0))
    (make-iterator (:type type)
      (when (>= index (length vector))
        (stop))
      (let ((value (aref vector index)))
        (incf index)
        (emit value)))))

(defun list-iterator (list &key type)
  (let ((cons list))
    (make-iterator (:type type)
      (when (eq nil cons)
        (stop))
      (let ((value (car cons)))
        (setf cons (cdr cons))
        (emit value)))))

(defun seq-iterator (seq &key type)
  (make-iterator (:type type)
    (when (equal 0 (fset:size seq))
      (stop))
    (let ((element (fset:first seq)))
      (setf seq (fset:less-first seq))
      (emit element))))

(defgeneric iterator (thing &key type &allow-other-keys))

(defmethod iterator ((list list) &key type &allow-other-keys)
  (list-iterator list :type type))

(defmethod iterator ((vector vector) &key type &allow-other-keys)
  (vector-iterator vector :type type))

(defmethod iterator ((seq fset:seq) &key type &allow-other-keys)
  (seq-iterator seq :type type))
