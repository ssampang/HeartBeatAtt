------------------------------------------------------------------------
--[[ SpatialGlimpse1D ]]--
-- Ref A.: http://papers.nips.cc/paper/5542-recurrent-models-of-visual-attention.pdf
-- a glimpse is the concatenation of down-scaled cropped images of 
-- increasing scale around a given location in a given image.
-- input is a pair of Tensors: {image, location}
-- locations are x,y coordinates of the center of cropped patches. 
-- Coordinates are between -1,-1 (top-left) and 1,1 (bottom right)
-- output is a batch of glimpses taken in image at location (x,y)
-- glimpse size is {height, width}, or width only if square-shaped
-- depth is number of patches to crop per glimpse (one patch per scale)
-- Each successive patch is scale x size of the previous patch
------------------------------------------------------------------------
local SpatialGlimpse1D, parent = torch.class("nn.SpatialGlimpse1D", "nn.Module")

function SpatialGlimpse1D:__init(size, depth, scale)
   require 'nnx'
   if torch.type(size)=='table' then
      self.height = size[1]
      self.width = size[2]
   else
      self.width = size
      self.height = size
   end
   self.depth = depth or 3
   self.scale = scale or 2
   
   assert(torch.type(self.width) == 'number')
   assert(torch.type(self.height) == 'number')
   assert(torch.type(self.depth) == 'number')
   assert(torch.type(self.scale) == 'number')
   parent.__init(self)
   self.gradInput = {torch.Tensor(), torch.Tensor()}
   if self.scale == 2 then
      self.module = nn.SpatialAveragePooling(2,1,2,1)
   else
      self.module = nn.SpatialReSampling{oheight=self.height,owidth=self.width}
   end
   self.modules = {self.module}
end

-- a bandwidth limited sensor which focuses on a location.
-- locations index the x,y coord of the center of the output glimpse
function SpatialGlimpse1D:updateOutput(inputTable)
   assert(torch.type(inputTable) == 'table')
   assert(#inputTable >= 2)
   local input, location = unpack(inputTable)
   input, location = self:toBatch(input, 3), self:toBatch(location, 1)
   assert(input:dim() == 4 and location:dim() == 2)
   
   self.output:resize(input:size(1), self.depth, input:size(2), self.height, self.width)
   
   self._crop = self._crop or self.output.new()
   self._pad = self._pad or input.new()
   
   for sampleIdx=1,self.output:size(1) do
      local outputSample = self.output[sampleIdx]
      local inputSample = input[sampleIdx]
      -- (-1,-1) top left corner, (1,1) bottom right corner of image
      local x = location[sampleIdx]:select(1,1)
      -- (0,0), (1,1)
      x = (x+1)/2
      
      -- for each depth of glimpse : pad, crop, downscale
      local glimpseWidth = self.width
      local glimpseHeight = self.height
      for depth=1,self.depth do 
         local dst = outputSample[depth]
         if depth > 1 then
            glimpseWidth = glimpseWidth*self.scale
            --glimpseHeight = glimpseHeight*self.scale
         end
         
         -- add zero padding (glimpse could be partially out of bounds)
         local padWidth = math.floor((glimpseWidth-1)/2)
         local padHeight = math.floor((glimpseHeight-1)/2)
         self._pad:resize(input:size(2), input:size(3)+padHeight*2, input:size(4)+padWidth*2):zero()
         local center = self._pad:narrow(3,padWidth+1,input:size(4))
         center:copy(inputSample)
         
         -- crop it
         local w =  self._pad:size(3)-glimpseWidth
         local x = math.min(w,math.max(0,x*w))
         
         if depth == 1 then
            dst:copy(self._pad:narrow(3,x+1,glimpseWidth))
         else
            self._crop:resize(input:size(2), glimpseHeight, glimpseWidth)
            self._crop:copy(self._pad:narrow(3,x+1,glimpseWidth))
         
            if torch.type(self.module) == 'nn.SpatialAveragePooling' then
               local poolWidth = glimpseWidth/self.width
               assert(poolWidth % 2 == 0)
               local poolHeight = glimpseHeight/self.height
               --assert(poolHeight % 2 == 0)
               self.module.kW = poolWidth
               --self.module.kH = poolHeight
               self.module.dW = poolWidth
               --self.module.dH = poolHeight
            end
--print( self._crop:size())
            dst:copy(self.module:updateOutput(self._crop))
         end
      end
   end
   
   self.output:resize(input:size(1), self.depth*input:size(2), self.height, self.width)
   self.output = self:fromBatch(self.output, 1)
--print(self.output:size())
   return self.output
end

function SpatialGlimpse1D:updateGradInput(inputTable, gradOutput)
   local input, location = unpack(inputTable)
   local gradInput, gradLocation = unpack(self.gradInput)
   input, location = self:toBatch(input, 3), self:toBatch(location, 1)
   gradOutput = self:toBatch(gradOutput, 3)
   
   gradInput:resizeAs(input):zero()
   gradLocation:resizeAs(location):zero() -- no backprop through location
   
   gradOutput = gradOutput:view(input:size(1), self.depth, input:size(2), self.height, self.width)
   
   for sampleIdx=1,gradOutput:size(1) do
      local gradOutputSample = gradOutput[sampleIdx]
      local gradInputSample = gradInput[sampleIdx]
      -- (-1,-1) top left corner, (1,1) bottom right corner of image
      local x = location[sampleIdx]:select(1,1)
      -- (0,0), (1,1)
      x = (x+1)/2
      
      -- for each depth of glimpse : pad, crop, downscale
      local glimpseWidth = self.width
      local glimpseHeight = self.height
      for depth=1,self.depth do 
         local src = gradOutputSample[depth]
         if depth > 1 then
            glimpseWidth = glimpseWidth*self.scale
            --glimpseHeight = glimpseHeight*self.scale
         end
         
         -- add zero padding (glimpse could be partially out of bounds)
         local padWidth = math.floor((glimpseWidth-1)/2)
         local padHeight = math.floor((glimpseHeight-1)/2)
         self._pad:resize(input:size(2), input:size(3)+padHeight*2, input:size(4)+padWidth*2):zero()
         
         local w = self._pad:size(3)-glimpseWidth
         local x = math.min(w,math.max(0,x*w))
         local pad = self._pad:narrow(3, x+1, glimpseWidth)
         
         -- upscale glimpse for different depths
         if depth == 1 then
            pad:copy(src)
         else
            self._crop:resize(input:size(2), glimpseHeight, glimpseWidth)
            
            if torch.type(self.module) == 'nn.SpatialAveragePooling' then
               local poolWidth = glimpseWidth/self.width
               assert(poolWidth % 2 == 0)
               local poolHeight = glimpseHeight/self.height
               --assert(poolHeight % 2 == 0)
               self.module.kW = poolWidth
               self.module.kH = poolHeight
               self.module.dW = poolWidth
               self.module.dH = poolHeight
            end
            
            pad:copy(self.module:updateGradInput(self._crop, src))
         end
        
         -- copy into gradInput tensor (excluding padding)
         gradInputSample:add(self._pad:narrow(3, padWidth+1, input:size(4)))
      end
   end
   
   self.gradInput[1] = self:fromBatch(gradInput, 1)
   self.gradInput[2] = self:fromBatch(gradLocation, 1)
   
   return self.gradInput
end
