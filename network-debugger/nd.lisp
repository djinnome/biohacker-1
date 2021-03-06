;; nd.lisp
(defmacro network-debugger (name
			    &key 
			    (debugging nil)
			    (rules nil)
			    (log nil)
			    (abducting nil)
			    (growth-patterns '((reaction-enabled ?r) (pathway-enabled ?p) (nutrient ?c)))
			    (no-growth-patterns '((:NOT (gene-on ?g)))))
  `(let ((nd (create-nd ',name :growth-patterns ',growth-patterns :no-growth-patterns ',no-growth-patterns :abducting ,abducting :rules ,rules :log ,log :debugging ,debugging)))
     (debugging-or-logging-nd
      "~%Network Debugger ~A" ',name)
     nd))

(defmacro reaction (name
		    &key
		    reactants
		    products
		    (reversible? :UNKNOWN)
		    (enzymes nil))
  `(ensure-network-open reaction
    (assert! '(reaction ,name ,reactants ,products ,reversible? ,enzymes)
	     :NETWORK)
    (debugging-nd
     "~%Adding reaction ~A." ',name)))

(defmacro enzyme (name &rest genes)
  `(ensure-network-open enzyme
    (assert! '(enzyme ,name ,@genes)
	     :NETWORK)
    (debugging-nd
     "~%Adding enzyme ~A." ',name)))

(defmacro pathway (name
		   &key
		   reactants
		   products
		   (reversible? nil)
		   (enzymes nil)
		   (reactions nil)
		   (proper-products nil proper-products?))
  (unless proper-products?
    (setq proper-products products))
  `(ensure-network-open pathway
    (assert! '(pathway ,name ,reactants ,products ,reversible? ,enzymes ,reactions ,proper-products)
	     :NETWORK)
    (debugging-nd
     "~%Adding pathway ~A." ',name)))

(defun experiment-knock-ins (experiment)
  (nth 7 experiment))

(defun experiment-knock-outs (experiment)
  (nth 8 experiment))

(defmacro experiment (name 
		      nutrients
		      &key
		      growth?
		      (knock-outs nil)
		      (knock-ins nil)
		      (toxins nil)
		      (bootstrap-compounds nil)
		      essential-compounds)
  `(ensure-network-closed 
    experiment
    (assert! '(experiment 
	       ,name ,growth? 
	       ,nutrients ,essential-compounds
	       ,bootstrap-compounds ,toxins
	       ,knock-ins ,knock-outs)
	     :EXPERIMENTS)
    (debugging-or-logging-nd
     "~%Adding experiment ~A" ',name)
    (run-rules-logging)
    (investigate-experiment ',name)
    ))

(defmacro ensure-network-open (demander &rest forms)
  `(if (nd-network-closed? *nd*)
       (error (format nil "Cannot add ~A as network closed." ',demander))
     (progn ,@forms)))

(defmacro ensure-network-closed (demander &rest forms)
  `(progn
     (when (not (nd-network-closed? *nd*))
       (debugging-or-logging-nd "~%Closing network for ~A." ',demander)
       (run-rules-logging)
       (assert! 'network-closed :ENSURE)
       (setf (nd-network-closed? *nd*) t)
       (run-rules-logging))
     ,@forms))

(defun retract-focus ()
  (dolist (fact (fetch '(focus-experiment ?e)))
    (when (already-assumed? fact)
      (retract! fact :INVESTIGATION)
      (debugging-nd
       "~%Retracting focus on experiment ~A." (cadr fact)))))

(defun change-focus-experiment (name)
  (retract-focus)
  (assume! `(focus-experiment ,name) :INVESTIGATION)
  (debugging-nd
   "~%Focusing on experiment ~A." name))

(defun investigate-experiment (name &aux result cache)
  (when-logging-nd
   "Investigating experiment ~A." name)
  (when (unknown? 'simplify-investigations) 
    (debugging-nd
     "~%Assuming simplify-investigations.")
    (assume! 'simplify-investigations :INVESTIGATION))
  (when (and (eq (nd-rules *nd*) :extended-reactions) (unknown? 'assume-unknowns-as-convenient)) 
    (debugging-nd
     "~%Assuming unknown genes and reaction reversibilities as convenient.")
    (assume! 'assume-unknowns-as-convenient :INVESTIGATION))  
  (change-focus-experiment name)
  (setq cache
	(assoc name (nd-findings *nd*)))
  (setq result (cdr cache))
  (unless cache
    (setq result (if (true? 'experiment-consistent) :CONSISTENT :NEEDS))
    (setf (nd-findings *nd*) (acons name result (nd-findings *nd*))))
  (if (nd-abducting *nd*)
    (abduct)
    (debugging-or-logging-nd
     "~%Experiment ~A ~A with model." name (if (eq :CONSISTENT result) "is consistent" "is not immediately consistent")))
  result)

(defun abduct (&aux result)
  (setq result
	(cond ((true? 'experiment-consistent)
	       :CONSISTENT)
	      ((true? 'experiment-growth)
	       (needs 'experiment-consistent :TRUE (nd-growth-patterns *nd*)))
	      ((false? 'experiment-growth)
	       (needs 'experiment-consistent :TRUE (nd-no-growth-patterns *nd*)))
	      (t (error "Experiment outcome is unknown!"))))
  (when-debugging-or-logging-nd
   (print-abduction result))
  result)

(defun print-abduction (result)
  (if (eq :CONSISTENT result) 
      (format t "~%Experiment is consistent with model.")
    (progn 
      (format t "~%Experiment is not consistent with model. Needs:")
      (pp-sets result t))))

(defun filter-findings-by-growth (growth? &optional (findings (nd-findings *nd*)))
  (remove-if-not
   #'(lambda (name)
       (fetch `(experiment ,name ,growth? . ?x)))
   findings
   :key #'car))

(defun filter-findings-by-consistence (consistent? &optional (findings (nd-findings *nd*)))
  (remove-if-not
   (if consistent?
       #'(lambda (result) (eq result :CONSISTENT))
     #'(lambda (result) (not (eq result :CONSISTENT))))
   findings
   :key #'cdr))

(defun summarize-findings (&aux positive negative false-negative false-positive growth no-growth summary)
  (setq growth (filter-findings-by-growth t))
  (setq no-growth (filter-findings-by-growth nil))
  (setq positive (filter-findings-by-consistence t growth))
  (setq negative (filter-findings-by-consistence t no-growth))
  (setq false-negative (filter-findings-by-consistence nil growth))
  (setq false-positive (filter-findings-by-consistence nil no-growth))
  (setq summary (list positive negative false-negative false-positive))
  (when-debugging-or-logging-nd
    (print-summary summary))
  summary)

(defun print-summary-line (about line)
  (format t "~%~A ~A findings: ~A" (list-length line) about (mapcar #'car line)))

(defun print-summary (summary)
  (print-summary-line "positive" (car summary))
  (print-summary-line "negative" (cadr summary))
  (print-summary-line "false-negative" (caddr summary))
  (print-summary-line "false-positive" (cadddr summary)))

(defun fix-for-experiment (name &aux cache)
  (if (setq cache (assoc name (nd-findings *nd*)))
      (cdr cache)
    :UNKNOWN-EXPERIMENT))

(defun minimize-nutrients (&aux name experiment nutrients min-nutrients extra-nutrients)
  (unless (and (true? 'experiment-growth)
	       (true? 'experiment-consistent)
	       (setq name (cadr (car (remove-if-not #'true? (fetch '(focus-experiment ?x))))))
	       (setq experiment (car (fetch `(experiment ,name . ?x)))))

    (debugging-nd "Focus experiment is not growth experiment or not consistent.")
    (return-from minimize-nutrients))
  (setq nutrients (cadddr experiment))
  (setq min-nutrients (mapcar #'cadr (all-antecedents 'experiment-consistent '((nutrient ?c)))))
  (setq extra-nutrients (remove-if #'(lambda (c) (find c min-nutrients)) nutrients))
  (debugging-or-logging-nd
   "~%Minimum nutrients for growth: ~A~%Unnecessary nutrients for growth: ~A" min-nutrients extra-nutrients)
  (list min-nutrients extra-nutrients))

(defun explicit-reversibility (&aux name experiment set unknown set-unknown)
  (unless (and (true? 'experiment-consistent)
	       (setq name (cadr (car (remove-if-not #'true? (fetch '(focus-experiment ?x))))))
	       (setq experiment (car (fetch `(experiment ,name . ?x)))))

    (debugging-nd "Focus experiment is not consistent.")
    (return-from explicit-reversibility))
  (setq 
   set
   (cond ((true? 'experiment-growth)
	  (mapcar #'cadr (all-antecedents 'experiment-consistent '((reaction-reversible ?r)))))
	 ((false? 'experiment-growth)
	  (mapcar #'cadadr (all-antecedents 'experiment-consistent '((:NOT (reaction-reversible ?r))))))
	 (t (error "Experiment outcome is not known."))))
  (setq
   unknown
   (mapcar #'cadr (fetch '(reaction ?name ?reactants ?products :UNKNOWN ?enzymes))))
  (setq set-unknown (intersection set unknown))
  (debugging-or-logging-nd
   "~%Reactions guessed to be ~A: ~A" (if (true? 'experiment-growth) "reversible" "irreversible") set-unknown)
  set-unknown)

(defun explicit-gene-expression (&aux name experiment set known set-unknown)
  (unless (and (true? 'experiment-consistent)
	       (setq name (cadr (car (remove-if-not #'true? (fetch '(focus-experiment ?x))))))
	       (setq experiment (car (fetch `(experiment ,name . ?x)))))
    (debugging-nd "Focus experiment is not consistent.")
    (return-from explicit-gene-expression))
  (setq 
   set
   (cond ((true? 'experiment-growth)
	  (mapcar #'cadr (all-antecedents 'experiment-consistent '((gene-on ?g)))))
	 ((false? 'experiment-growth)
	  (mapcar #'cadadr (all-antecedents 'experiment-consistent '((:NOT (gene-on ?g))))))
	 (t (error "Experiment outcome is not known."))))
  (setq 
   known
   (funcall (if (true? 'experiment-growth) #'experiment-knock-ins #'experiment-knock-outs) experiment))
  (setq set-unknown (remove-if #'(lambda (g) (find g known)) set))
  (debugging-or-logging-nd
   "~%Genes guessed to be ~A: ~A" (if (true? 'experiment-growth) "on" "off") set-unknown)
  set-unknown)

(defun explicit-nutrients (&aux name experiment set known set-unknown)
  (unless (and (true? 'experiment-consistent)
	       (setq name (cadr (car (remove-if-not #'true? (fetch '(focus-experiment ?x))))))
	       (setq experiment (car (fetch `(experiment ,name . ?x)))))
    (debugging-nd "Focus experiment is not consistent.")
    (return-from explicit-nutrients))
  (setq 
   set
   (cond ((true? 'experiment-growth)
	  (mapcar #'cadr (all-antecedents 'experiment-consistent '((nutrient ?c)))))
	 ((false? 'experiment-growth)
	  (mapcar #'cadadr (all-antecedents 'experiment-consistent '((:NOT (nutrient ?c))))))
	 (t (error "Experiment outcome is not known."))))
  (setq set-unknown set)
  (when (true? 'experiment-growth)
    (setq known (cadddr experiment))
    (setq set-unknown
	  (remove-if #'(lambda (c) (find c known)) set)))
  (debugging-or-logging-nd
   "~%Nutrients guessed to be ~A: ~A" (if (true? 'experiment-growth) "present" "absent") set-unknown)
  set-unknown)

(defun nd-forward-needs ()
  (cond ((true? 'experiment-growth)
	 (needs-forward 'experiment-consistent :TRUE '((reaction-enabled ?r) (nutrient ?x))))
	((false? 'experiment-growth)
	 (needs-forward 'experiment-consistent :TRUE '((:NOT (gene-on ?g)))))))
