require 'paths'
require 'rnn'
require 'nngraph'
local dl = require 'dataload'
assert(nn.NCEModule and nn.NCEModule.version and nn.NCEModule.version >= 3, "update dpnn : luarocks install dpnn")

--[[ command line arguments ]]--
cmd = torch.CmdLine()
cmd:text()
cmd:text('Train a Language Model using stacked LSTM on Google Billion Words dataset')
cmd:text('Example:')
cmd:text("th noise-contrastive-estimate.lua --progress --earlystop 50 --cuda --device 2 --seqlen 20 --hiddensize '{200,200}' --batchsize 20 --startlr 1 --uniform 0.1 --cutoff 5 --schedule '{[5]=0.5,[6]=0.25,[7]=0.125,[8]=0.0625,[9]=0.03125,[10]=0.015625,[11]=0.0078125,[12]=0.00390625}'")
cmd:text("th examples/noise-contrastive-estimate.lua --cuda --trainsize 400000 --validsize 40000 --cutoff 10 --batchsize 128 --seqlen 100 --hiddensize '{250,250}' --progress --device 2")
cmd:text("th scripts/evaluate-rnnlm.lua --xplogpath /data/save/rnnlm/ptb:atlas:1458081269:1.t7 --cuda")
cmd:text('Options:')
-- training
cmd:option('--startlr', 0.05, 'learning rate at t=0')
cmd:option('--minlr', 0.00001, 'minimum learning rate')
cmd:option('--saturate', 400, 'epoch at which linear decayed LR will reach minlr')
cmd:option('--schedule', '', 'learning rate schedule. e.g. {[5] = 0.004, [6] = 0.001}')
cmd:option('--momentum', 0.9, 'momentum')
cmd:option('--maxnormout', -1, 'max l2-norm of each layer\'s output neuron weights')
cmd:option('--cutoff', -1, 'max l2-norm of concatenation of all gradParam tensors')
cmd:option('--cuda', false, 'use CUDA')
cmd:option('--device', 1, 'sets the device (GPU) to use')
cmd:option('--profile', false, 'profile updateOutput,updateGradInput and accGradParameters in Sequential')
cmd:option('--maxepoch', 1000, 'maximum number of epochs to run')
cmd:option('--earlystop', 50, 'maximum number of epochs to wait to find a better local minima for early-stopping')
cmd:option('--progress', false, 'print progress bar')
cmd:option('--silent', false, 'don\'t print anything to stdout')
cmd:option('--uniform', 0.1, 'initialize parameters using uniform distribution between -uniform and uniform. -1 means default initialization')
cmd:option('--k', 25, 'how many noise samples to use for NCE')
cmd:option('--continue', '', 'path to model for which training should be continued. Note that current options (except for device, cuda and tiny) will be ignored.')
cmd:option('--Z', -1, 'normalization constant for NCE module (-1 approximates it from first batch).')
-- rnn layer 
cmd:option('--seqlen', 50, 'sequence length : back-propagate through time (BPTT) for this many time-steps')
cmd:option('--inputsize', -1, 'size of lookup table embeddings. -1 defaults to hiddensize[1]')
cmd:option('--hiddensize', '{200,200}', 'number of hidden units used at output of each recurrent layer. When more than one is specified, RNN/LSTMs/GRUs are stacked')
cmd:option('--dropout', 0, 'ancelossy dropout with this probability after each rnn layer. dropout <= 0 disables it.')
-- data
cmd:option('--batchsize', 32, 'number of examples per batch')
cmd:option('--trainsize', -1, 'number of train time-steps seen between each epoch')
cmd:option('--validsize', -1, 'number of valid time-steps used for early stopping and cross-validation') 
cmd:option('--savepath', paths.concat(dl.SAVE_PATH, 'rnnlm'), 'path to directory where experiment log (includes model) will be saved')
cmd:option('--id', '', 'id string of this experiment (used to name output file) (defaults to a unique id)')
cmd:option('--tiny', false, 'use train_tiny.th7 training file')
cmd:option('--dontsave', false, 'dont save the model')
cmd:option('--cpulookup', false, 'keep lookuptable on CPU')

cmd:text()
local opt = cmd:parse(arg or {})
opt.hiddensize = loadstring(" return "..opt.hiddensize)()
opt.schedule = loadstring(" return "..opt.schedule)()
opt.inputsize = opt.inputsize == -1 and opt.hiddensize[1] or opt.inputsize
if not opt.silent then
   table.print(opt)
end
opt.id = opt.id == '' and ('gbw' .. ':' .. dl.uniqueid()) or opt.id
opt.version = 4

if opt.cuda then -- do this before building model to prevent segfault
   require 'cunn' 
   cutorch.setDevice(opt.device)
end 

local xplog, lm, criterion, targetmodule
if opt.continue ~= '' then
   xplog = torch.load(opt.continue)
   xplog.opt.cuda = opt.cuda
   xplog.opt.device = opt.device
   xplog.opt.tiny = opt.tiny
   opt = xplog.opt
   lm = xplog.model.module
   -- prevent re-casting bug
   for i,lookup in ipairs(lm:findModules('nn.LookupTableMaskZero')) do
      lookup.__input = nil
   end
   criterion = xplog.criterion
   targetmodule = xplog.targetmodule
   assert(opt)
end

--[[ data set ]]--

local trainset, validset, testset = dl.loadGBW({opt.batchsize,opt.batchsize,opt.batchsize}, opt.tiny and 'train_tiny.th7' or nil)
if not opt.silent then 
   print("Vocabulary size : "..#trainset.ivocab) 
   print("Train set split into "..opt.batchsize.." sequences of length "..trainset:size())
end

--[[ language model ]]--

if not lm then
   lm = nn.Sequential()

   -- input layer (i.e. word embedding space)
   local lookup = nn.LookupTableMaskZero(#trainset.ivocab, opt.inputsize)
   lookup.maxnormout = -1 -- prevent weird maxnormout behaviour
   if opt.cpulookup then
      lookup = nn.DontCast(lookup:float(), false, true)
   end
   lm:add(lookup) -- input is seqlen x batchsize
   if opt.dropout > 0 then
      lm:add(nn.Dropout(opt.dropout))
   end

   -- rnn layers
   local inputsize = opt.inputsize
   for i,hiddensize in ipairs(opt.hiddensize) do
      -- this is a faster version of nnSequencer(nn.FastLSTM(inpusize, hiddensize))
      local rnn = nn.SeqLSTM(inputsize, hiddensize)
      rnn.maskzero = true
      lm:add(rnn)
      if opt.dropout > 0 then
         lm:add(nn.Dropout(opt.dropout))
      end
      inputsize = hiddensize
   end

   lm:add(nn.SplitTable(1))

   -- output layer
   local unigram = trainset.wordfreq:float()
   local ncemodule = nn.NCEModule(inputsize, #trainset.ivocab, opt.k, unigram, opt.Z)

   -- NCE requires {input, target} as inputs
   lm = nn.Sequential()
      :add(nn.ParallelTable()
         :add(lm):add(nn.Identity()))
      :add(nn.ZipTable()) -- {{x1,x2,...}, {t1,t2,...}} -> {{x1,t1},{x2,t2},...}

   -- encapsulate stepmodule into a Sequencer
   lm:add(nn.Sequencer(nn.MaskZero(ncemodule, 1)))

   -- remember previous state between batches
   lm:remember()

   if opt.uniform > 0 then
      for k,param in ipairs(lm:parameters()) do
         param:uniform(-opt.uniform, opt.uniform)
      end
   end
end

if opt.profile then
   lm:profile()
end

if not opt.silent then
   print"Language Model:"
   print(lm)
end

if not (criterion and targetmodule) then
   --[[ loss function ]]--

   local crit = nn.MaskZeroCriterion(nn.NCECriterion(), 0)

   -- target is also seqlen x batchsize.
   targetmodule = nn.SplitTable(1)
   if opt.cuda then
      targetmodule = nn.Sequential()
         :add(nn.Convert())
         :add(targetmodule)
   end
    
   criterion = nn.SequencerCriterion(crit)
end

--[[ CUDA ]]--

if opt.cuda then
   lm:cuda()
   criterion:cuda()
   targetmodule:cuda()
end

--[[ experiment log ]]--

-- is saved to file every time a new validation minima is found
if not xplog then
   xplog = {}
   xplog.opt = opt -- save all hyper-parameters and such
   xplog.dataset = 'GoogleBillionWords'
   xplog.vocab = trainset.vocab
   -- will only serialize params
   xplog.model = nn.Serial(lm)
   xplog.model:mediumSerial()
   xplog.criterion = criterion
   xplog.targetmodule = targetmodule
   -- keep a log of NLL for each epoch
   xplog.trainnceloss = {}
   xplog.valnceloss = {}
   -- will be used for early-stopping
   xplog.minvalnceloss = 99999999
   xplog.epoch = 0
   paths.mkdir(opt.savepath)
end
local ntrial = 0

local epoch = xplog.epoch+1
opt.lr = opt.lr or opt.startlr
opt.trainsize = opt.trainsize == -1 and trainset:size() or opt.trainsize
opt.validsize = opt.validsize == -1 and validset:size() or opt.validsize
while opt.maxepoch <= 0 or epoch <= opt.maxepoch do
   print("")
   print("Epoch #"..epoch.." :")

   -- 1. training
   
   local a = torch.Timer()
   lm:training()
   local sumErr = 0
   for i, inputs, targets in trainset:subiter(opt.seqlen, opt.trainsize) do
      targets = targetmodule:forward(targets)
      inputs = {inputs, targets}
      -- forward
      local outputs = lm:forward(inputs)
      local err = criterion:forward(outputs, targets)
      sumErr = sumErr + err
      -- backward 
      local gradOutputs = criterion:backward(outputs, targets)
      local a = torch.Timer()
      lm:zeroGradParameters()
      lm:backward(inputs, gradOutputs)
      
      -- update
      if opt.cutoff > 0 then
         local norm = lm:gradParamClip(opt.cutoff) -- affects gradParams
         opt.meanNorm = opt.meanNorm and (opt.meanNorm*0.9 + norm*0.1) or norm
      end
      lm:updateGradParameters(opt.momentum) -- affects gradParams
      lm:updateParameters(opt.lr) -- affects params
      lm:maxParamNorm(opt.maxnormout) -- affects params

      if opt.progress then
         xlua.progress(i, opt.trainsize)
      end

      if i % 2000 == 0 then
         collectgarbage()
      end

   end
   
   -- learning rate decay
   if opt.schedule then
      opt.lr = opt.schedule[epoch] or opt.lr
   else
      opt.lr = opt.lr + (opt.minlr - opt.startlr)/opt.saturate
   end
   opt.lr = math.max(opt.minlr, opt.lr)
   
   if not opt.silent then
      print("learning rate", opt.lr)
      if opt.meanNorm then
         print("mean gradParam norm", opt.meanNorm)
      end
   end

   if cutorch then cutorch.synchronize() end
   local speed = opt.trainsize*opt.batchsize/a:time().real
   print(string.format("Speed : %f words/second; %f ms/word", speed, 1000/speed))

   local nceloss = sumErr/opt.trainsize
   print("Training error : "..nceloss)

   xplog.trainnceloss[epoch] = nceloss

   -- 2. cross-validation

   lm:evaluate()
   local sumErr = 0
   for i, inputs, targets in validset:subiter(opt.seqlen, opt.validsize) do
      targets = targetmodule:forward(targets)
      local outputs = lm:forward{inputs, targets}
      local err = criterion:forward(outputs, targets)
      sumErr = sumErr + err
      
      if opt.progress then
         xlua.progress(i, opt.validsize)
      end
   end

   local nceloss = sumErr/opt.validsize
   print("Validation error : "..nceloss)

   xplog.valnceloss[epoch] = nceloss
   ntrial = ntrial + 1

   -- early-stopping
   if nceloss < xplog.minvalnceloss then
      -- save best version of model
      xplog.minvalnceloss = nceloss
      xplog.epoch = epoch 
      local filename = paths.concat(opt.savepath, opt.id..'.t7')
      print("Found new minima. Saving to "..filename)
      if not opt.dontsave then
         torch.save(filename, xplog)
      end
      ntrial = 0
   elseif ntrial >= opt.earlystop then
      print("No new minima found after "..ntrial.." epochs.")
      print("Stopping experiment.")
      print("Best model can be found in "..paths.concat(opt.savepath, opt.id..'.t7'))
      os.exit()
   end

   collectgarbage()
   epoch = epoch + 1
end
